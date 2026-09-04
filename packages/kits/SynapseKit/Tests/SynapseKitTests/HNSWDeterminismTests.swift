// HNSWDeterminismTests.swift
//
// HNSW-DETERMINISM: content-stable bulk graph build order.
//
// The bulk rebuild path (compact(), and VectorStore.rebuildHNSWIndex which
// applies the same ordering before insertion) sorts rows by
// (fnv1a64(payload bytes) ASC, itemID ASC) before inserting, so building
// from the SAME row set in ANY arrival order yields the IDENTICAL graph.
// Incremental single-row inserts keep arrival order — only bulk rebuilds
// guarantee cross-run identity (SPEC 1.10.0).
//
// The test builds the same 60-row corpus twice in two different arrival
// orders, runs the bulk path (compact), and asserts the two graphs are
// identical: same serialized neighbour lists row-for-row, and the same
// (itemID, distance) result sequence for a probe.

import Testing
import Foundation
@testable import SynapseKit

/// SplitMix64 (same algorithm as HNSWIndex's RNG) — local copy; the one in
/// HNSWIndexTests.swift is fileprivate to that file.
private struct DetSplitMix64 {
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
        let f = Float(bits) / Float(UInt32.max)
        return f * 2.0 - 1.0
    }
}

@Suite("HNSW content-stable bulk build order")
struct HNSWDeterminismTests {

    /// Bulk path: same rows, two different insertion orders → identical graph.
    @Test func bulkRebuildIsContentStableAcrossArrivalOrders() async throws {
        let dim = 8
        let n = 60
        var rng = DetSplitMix64(state: 7)
        let corpus: [(itemID: String, vector: [Float])] = (0..<n).map { i in
            var v = (0..<dim).map { _ in rng.nextFloat() }
            let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { for j in v.indices { v[j] /= norm } }
            return (itemID: String(format: "item-%03d", i), vector: v)
        }

        // Arrival order 1: natural. Arrival order 2: reversed.
        // Both consume the same number of RNG draws before compact(), so the
        // level-assignment sequence at rebuild time is identical — any graph
        // difference can only come from insertion ORDER.
        let idx1 = HNSWIndex()
        for e in corpus {
            await idx1.insert(itemID: e.itemID, modelID: "model-x", vector: e.vector)
        }
        await idx1.compact()

        let idx2 = HNSWIndex()
        for e in corpus.reversed() {
            await idx2.insert(itemID: e.itemID, modelID: "model-x", vector: e.vector)
        }
        await idx2.compact()

        // Graph identity: row-for-row identical (nodeID, layer, neighbour list).
        let rows1 = await idx1.graphRows()
        let rows2 = await idx2.graphRows()
        #expect(rows1.count == rows2.count)
        for (r1, r2) in zip(rows1, rows2) {
            #expect(r1.nodeID == r2.nodeID)
            #expect(r1.layer == r2.layer)
            #expect(r1.decodeNeighbours() == r2.decodeNeighbours())
        }

        // Probe identity: identical (itemID, distance) sequence from both graphs.
        var probeRng = DetSplitMix64(state: 99)
        var probe = (0..<dim).map { _ in probeRng.nextFloat() }
        let pNorm = probe.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        if pNorm > 0 { for j in probe.indices { probe[j] /= pNorm } }

        let hits1 = try await idx1.search(probe: probe, modelID: "model-x", k: 10)
        let hits2 = try await idx2.search(probe: probe, modelID: "model-x", k: 10)
        #expect(hits1.map(\.itemID) == hits2.map(\.itemID))
        #expect(hits1.map(\.distance) == hits2.map(\.distance))
    }
}
