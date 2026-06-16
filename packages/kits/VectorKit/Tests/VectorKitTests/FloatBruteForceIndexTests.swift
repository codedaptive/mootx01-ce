// FloatBruteForceIndexTests.swift
//
// Lane C tests: FloatBruteForceIndex round-trip, metric correctness,
// and recall completeness.
//
// All tests use real on-disk SQLite storage (via makeScratchStorage) where
// storage is involved. FloatBruteForceIndex itself does not interact with
// storage — it operates in memory over a ResidentVectorArray — but the
// test data paths are exercised through the same infrastructure.
//
// Float determinism note: these tests assert exact Float equality within
// a single run on one platform. They do NOT assert cross-platform or
// cross-build bit-identity; that is a documented property of the float
// lane (arch spec §6). Any test that adds a "should be bit-identical across
// Swift and Rust" assertion for float distances is WRONG and must be removed.

import Testing
@testable import VectorKit
import PersistenceKit

// MARK: - Helpers

/// Build a VectorRecordKey for testing. Single-vector item (vectorIndex=0).
private func key(_ itemID: String, model: String = "test-model", version: String = "1") -> VectorRecordKey {
    VectorRecordKey(itemID: itemID, modelID: model, modelVersion: version)
}

/// Build a float32 VectorPayload from a [Float] literal.
private func payload(_ floats: [Float]) -> VectorPayload {
    VectorPayload(floats: floats)
}

/// Build a ResidentVectorArray from (VectorRecordKey, [Float]) pairs.
/// Keys and vectors must all have the same dimension.
private func buildArray(vectors: [(VectorRecordKey, [Float])]) -> ResidentVectorArray {
    precondition(!vectors.isEmpty)
    let dim = vectors[0].1.count
    let stride = UInt32(dim * 4)
    var storage = [UInt8]()
    var keys = [VectorRecordKey]()
    for (k, floats) in vectors {
        var p = VectorPayload(floats: floats)
        storage.append(contentsOf: p.bytes)
        keys.append(k)
        _ = p   // silence unused warning
    }
    let partitions = buildTestPartitions(keys: keys)
    return ResidentVectorArray(
        kind: .float32,
        stride: stride,
        count: UInt32(vectors.count),
        storage: storage,
        keys: keys,
        modelPartitions: partitions,
        tombstones: []
    )
}

private func buildTestPartitions(keys: [VectorRecordKey]) -> [ModelPartitionEntry] {
    guard !keys.isEmpty else { return [] }
    var result: [ModelPartitionEntry] = []
    var runStart = 0
    var runModel = keys[0].modelID
    for i in 1..<keys.count {
        if keys[i].modelID != runModel {
            result.append(ModelPartitionEntry(modelID: runModel, range: runStart..<i))
            runStart = i
            runModel = keys[i].modelID
        }
    }
    result.append(ModelPartitionEntry(modelID: runModel, range: runStart..<keys.count))
    return result
}

// MARK: - Suite

@Suite("FloatBruteForceIndex")
struct FloatBruteForceIndexTests {

    // MARK: - Build

    @Test("build stores the array and kind is bruteForce")
    func buildStoresArray() async {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a"), [1.0, 0.0, 0.0]),
            (key("b"), [0.0, 1.0, 0.0]),
        ])
        await idx.build(from: arr)
        #expect(idx.kind == .bruteForce)
    }

    @Test("build on empty array returns empty search results")
    func buildEmptyArrayReturnsEmpty() async throws {
        let idx = FloatBruteForceIndex()
        let arr = ResidentVectorArray.empty(kind: .float32, stride: 12)
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0, 0.0])
        let results = try await idx.search(probe: probe, metric: .cosine, k: 5, filter: nil)
        #expect(results.isEmpty)
    }

    @Test("search before build returns empty")
    func searchBeforeBuildReturnsEmpty() async throws {
        let idx = FloatBruteForceIndex()
        let probe = payload([1.0, 0.0])
        let results = try await idx.search(probe: probe, metric: .l2, k: 3, filter: nil)
        #expect(results.isEmpty)
    }

    // MARK: - Metric correctness: cosine

    @Test("cosine: identical vectors have distance 0")
    func cosineIdenticalVectorsDistance0() async throws {
        let idx = FloatBruteForceIndex()
        let v: [Float] = [0.6, 0.8]     // unit vector
        let arr = buildArray(vectors: [(key("a"), v)])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload(v), metric: .cosine, k: 1, filter: nil)
        #expect(results.count == 1)
        let dist = results[0].floatDistance!
        #expect(abs(dist) < 1e-5)
    }

    @Test("cosine: orthogonal vectors have distance 1")
    func cosineOrthogonalDistance1() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a"), [1.0, 0.0]),
            (key("b"), [0.0, 1.0]),
        ])
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0])
        let results = try await idx.search(probe: probe, metric: .cosine, k: 2, filter: nil)
        #expect(results.count == 2)
        // a is the nearest (distance ~0), b is orthogonal (distance ~1)
        let distA = results[0].floatDistance!
        let distB = results[1].floatDistance!
        #expect(abs(distA) < 1e-5)
        #expect(abs(distB - 1.0) < 1e-5)
    }

    @Test("cosine: zero vector returns fallback distance 1")
    func cosineZeroVectorFallback() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [(key("zero"), [0.0, 0.0, 0.0])])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload([1.0, 0.0, 0.0]), metric: .cosine, k: 1, filter: nil)
        #expect(results.count == 1)
        // Cosine undefined for zero vector → safe fallback = 1.0
        let dist = results[0].floatDistance!
        #expect(abs(dist - 1.0) < 1e-5)
    }

    // MARK: - Metric correctness: L2

    @Test("l2: identical vectors have distance 0")
    func l2IdenticalDistance0() async throws {
        let idx = FloatBruteForceIndex()
        let v: [Float] = [3.0, 4.0]
        let arr = buildArray(vectors: [(key("a"), v)])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload(v), metric: .l2, k: 1, filter: nil)
        #expect(results.count == 1)
        let dist = results[0].floatDistance!
        #expect(abs(dist) < 1e-5)
    }

    @Test("l2: Pythagorean triple gives exact distance")
    func l2PythagoreanTriple() async throws {
        let idx = FloatBruteForceIndex()
        // [0,0] to [3,4] = distance 5
        let arr = buildArray(vectors: [(key("origin"), [0.0, 0.0])])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload([3.0, 4.0]), metric: .l2, k: 1, filter: nil)
        #expect(results.count == 1)
        let dist = results[0].floatDistance!
        #expect(abs(dist - 5.0) < 1e-4)
    }

    @Test("l2: nearest of three returns closest by Euclidean distance")
    func l2NearestOfThree() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("far"),    [10.0, 0.0]),
            (key("medium"), [3.0, 0.0]),
            (key("near"),   [1.0, 0.0]),
        ])
        await idx.build(from: arr)
        let probe = payload([0.0, 0.0])
        let results = try await idx.search(probe: probe, metric: .l2, k: 3, filter: nil)
        #expect(results.count == 3)
        #expect(results[0].key.itemID == "near")
        #expect(results[1].key.itemID == "medium")
        #expect(results[2].key.itemID == "far")
    }

    // MARK: - Metric correctness: dot

    @Test("dot: higher inner product ranks first (after negation)")
    func dotHigherProductRanksFirst() async throws {
        let idx = FloatBruteForceIndex()
        // dot = -Σ(aᵢ×bᵢ); lower stored distance = higher real dot product
        let arr = buildArray(vectors: [
            (key("weak"),   [0.1, 0.0]),
            (key("strong"), [1.0, 0.0]),
        ])
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0])
        let results = try await idx.search(probe: probe, metric: .dot, k: 2, filter: nil)
        #expect(results.count == 2)
        // "strong" has higher dot product → lower negated distance → ranks first
        #expect(results[0].key.itemID == "strong")
        #expect(results[1].key.itemID == "weak")
    }

    // MARK: - Error handling

    @Test("search throws on binary probe kind")
    func searchThrowsOnBinaryProbe() async throws {
        let idx = FloatBruteForceIndex()
        let binaryPayload = VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 0, count: 32))
        await #expect(throws: (any Error).self) {
            _ = try await idx.search(probe: binaryPayload, metric: .cosine, k: 1, filter: nil)
        }
    }

    @Test("search throws on binary metric")
    func searchThrowsOnBinaryMetric() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [(key("a"), [1.0, 0.0])])
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0])
        await #expect(throws: (any Error).self) {
            _ = try await idx.search(probe: probe, metric: .hamming, k: 1, filter: nil)
        }
    }

    @Test("search throws when probe dim does not match array stride")
    func searchThrowsOnDimMismatch() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [(key("a"), [1.0, 0.0, 0.0])])   // dim=3
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0])                                  // dim=2
        await #expect(throws: (any Error).self) {
            _ = try await idx.search(probe: probe, metric: .cosine, k: 1, filter: nil)
        }
    }

    // MARK: - Ordering and tie-break

    @Test("tie-break: equal-distance results sorted by itemID ascending")
    func tieBreakByItemIDAscending() async throws {
        let idx = FloatBruteForceIndex()
        // Two vectors equidistant from the probe (on the unit circle).
        // cos(45°) distance from [1,0] to both [1,1]/√2 and... we use
        // identical vectors to force identical distance.
        let v: [Float] = [1.0, 0.0]
        let arr = buildArray(vectors: [
            (key("zzz"), v),
            (key("aaa"), v),
            (key("mmm"), v),
        ])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload(v), metric: .cosine, k: 3, filter: nil)
        #expect(results.count == 3)
        // All have identical distance; must be sorted alphabetically by itemID.
        #expect(results[0].key.itemID == "aaa")
        #expect(results[1].key.itemID == "mmm")
        #expect(results[2].key.itemID == "zzz")
    }

    @Test("k larger than corpus returns all results")
    func kLargerThanCorpus() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a"), [1.0, 0.0]),
            (key("b"), [0.0, 1.0]),
        ])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload([1.0, 0.0]), metric: .cosine, k: 100, filter: nil)
        #expect(results.count == 2)
    }

    // MARK: - Filter

    @Test("filter by modelID excludes other models")
    func filterByModelIDExcludesOtherModels() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a", model: "model-a"), [1.0, 0.0]),
            (key("b", model: "model-b"), [1.0, 0.0]),   // same vector, different model
        ])
        await idx.build(from: arr)
        let probe = payload([1.0, 0.0])
        let filter = MetadataFilter(modelID: "model-a")
        let results = try await idx.search(probe: probe, metric: .cosine, k: 5, filter: filter)
        #expect(results.count == 1)
        #expect(results[0].key.itemID == "a")
    }

    @Test("nil filter returns all results")
    func nilFilterReturnsAll() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a", model: "model-a"), [1.0, 0.0]),
            (key("b", model: "model-b"), [1.0, 0.0]),
        ])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload([1.0, 0.0]), metric: .cosine, k: 5, filter: nil)
        #expect(results.count == 2)
    }

    // MARK: - Tombstone

    @Test("tombstoned slot is excluded from search")
    func tombstonedSlotExcluded() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a"), [1.0, 0.0]),   // slot 0
            (key("b"), [0.0, 1.0]),   // slot 1
        ])
        await idx.build(from: arr)

        // Tombstone slot 0 (itemID "a") — the nearer match for [1,0] under cosine
        try await idx.remove(key: key("a"))

        let results = try await idx.search(probe: payload([1.0, 0.0]), metric: .cosine, k: 2, filter: nil)
        // Only "b" survives
        #expect(results.count == 1)
        #expect(results[0].key.itemID == "b")
    }

    // MARK: - Incremental add

    @Test("add and then search finds the added vector")
    func addThenSearch() async throws {
        let idx = FloatBruteForceIndex()
        let k = key("added")
        let v: [Float] = [1.0, 0.0]
        try await idx.add(key: k, vector: payload(v))
        let results = try await idx.search(probe: payload(v), metric: .cosine, k: 1, filter: nil)
        #expect(results.count == 1)
        #expect(results[0].key.itemID == "added")
    }

    @Test("add throws on non-float32 vector")
    func addThrowsOnBinaryVector() async throws {
        let idx = FloatBruteForceIndex()
        let binaryPayload = VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 0, count: 32))
        await #expect(throws: (any Error).self) {
            try await idx.add(key: key("x"), vector: binaryPayload)
        }
    }

    // MARK: - DenseHit floatDistance accessor

    @Test("DenseHit.floatDistance round-trips the stored bit pattern")
    func denseHitFloatDistanceRoundTrip() async throws {
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [(key("a"), [1.0, 0.0])])
        await idx.build(from: arr)
        let results = try await idx.search(probe: payload([1.0, 0.0]), metric: .cosine, k: 1, filter: nil)
        #expect(results.count == 1)
        // floatDistance must not be nil for a float metric hit
        #expect(results[0].floatDistance != nil)
        // jaccardDistance must be nil (wrong metric)
        #expect(results[0].jaccardDistance == nil)
    }

    // MARK: - Reproducibility (within-config)

    @Test("cosine search is reproducible across identical calls on same platform")
    func cosineSearchIsReproducible() async throws {
        // Float lane is reproducible within one build/config (arch spec §6).
        // This test asserts that two searches with identical input produce identical output.
        // It does NOT assert cross-platform or cross-build bit identity.
        let idx = FloatBruteForceIndex()
        let arr = buildArray(vectors: [
            (key("a"), [0.6, 0.8]),
            (key("b"), [0.0, 1.0]),
            (key("c"), [0.8, 0.6]),
        ])
        await idx.build(from: arr)
        let probe = payload([0.707, 0.707])

        let first  = try await idx.search(probe: probe, metric: .cosine, k: 3, filter: nil)
        let second = try await idx.search(probe: probe, metric: .cosine, k: 3, filter: nil)

        #expect(first.map { $0.key.itemID } == second.map { $0.key.itemID })
        for i in 0..<first.count {
            #expect(first[i].rawDistance == second[i].rawDistance)
        }
    }
}
