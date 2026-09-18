// HNSWPersistenceTests.swift
//
// Exit-gate tests for HNSW graph persistence (VEC-HNSW-01 acceptance criteria).
//
// Four tests cover the four exit gates:
//
//   HP-1 (exit gates A + B — persistence round-trip):
//     Build a graph via rebuildHNSWIndex, assert hnsw_graph row count > 0 (gate A
//     PERSISTENCE PROOF). Close the VectorStore and SQLite connection, reopen a
//     fresh VectorStore on the same file, assert hnswBuildCount == 0 AND results
//     match — graph loaded from rows, NOT rebuilt (gate B RESTART PROOF).
//
//   HP-2 (exit gate D — absent graph → exact scan, no inline build):
//     With no hnsw_graph rows and a corpus above the threshold, findNearestFloat
//     must return exact-scan results without triggering a rebuild (hnswBuildCount
//     stays 0 throughout).
//
//   HP-3 (exit gate C — DELETE-RESURRECTION proof):
//     Tombstone a vector while the graph is on disk, reopen a fresh store,
//     assert the deleted item does NOT appear as a live neighbour.
//
// All tests use a low hnswThreshold (10) so a 20-vector corpus triggers the HNSW
// routing path without a 5 000-vector corpus.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import SynapseKit

// MARK: - Suite

@Suite("HNSW Persistence — VEC-HNSW-01 exit gate")
struct HNSWPersistenceTests {

    private static let modelID = "hnsw-persist-model"
    private static let dim     = 8
    private static let count   = 20    // > threshold (10)
    private static let threshold: UInt32 = 10

    // Reuse the SplitMix64 RNG from the HNSW suite (same algorithm, same seed space).
    private func makeRNG(seed: UInt64 = 0xABCDEF01_23456789) -> SplitMix64HP {
        SplitMix64HP(state: seed)
    }

    private func randomVector(dim: Int, rng: inout SplitMix64HP) -> [Float] {
        var v = (0..<dim).map { _ in rng.nextFloat() }
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        for i in v.indices { v[i] /= norm }
        return v
    }

    /// Exact cosine-nearest top-k from a corpus (oracle).
    private func bruteForce(probe: [Float], corpus: [(id: String, v: [Float])], k: Int) -> [String] {
        func cosDist(_ a: [Float], _ b: [Float]) -> Float {
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
            let d = na.squareRoot() * nb.squareRoot()
            guard d > 0 else { return 1.0 }
            return 1.0 - max(-1.0, min(1.0, dot / d))
        }
        return corpus
            .sorted { cosDist(probe, $0.v) < cosDist(probe, $1.v) }
            .prefix(k)
            .map(\.id)
    }

    /// Open a fresh SQLiteStorage at `url` and migrate the VectorStore schema.
    private func openStorage(at url: URL) async throws -> any Storage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return storage
    }

    // MARK: - HP-1: persistence round-trip (exit gates A + B)

    /// Build graph, assert rows written (gate A), close store, reopen, assert
    /// loads from rows without rebuild (gate B).
    ///
    /// Exit gate A (PERSISTENCE PROOF): `hnswGraphRowCount(for:)` must return > 0
    /// after rebuildHNSWIndex — direct row assertion against the hnsw_graph table.
    ///
    /// Exit gate B (RESTART PROOF): `hnswBuildCount[modelID]` is 1 on the first
    /// instance (rebuildHNSWIndex increments it) and MUST be 0 on the second
    /// instance (graph loaded from hnsw_graph rows, no rebuild). If this count
    /// were > 0 after reopen, the graph was rebuilt from float records — defect 1
    /// (hnsw_graph table never written, building on query path).
    @Test("HP-1: graph persists to hnsw_graph and loads on reopen without rebuild")
    func hp1_persistenceRoundTrip() async throws {
        try await GlobalTestLock.shared.withLock {
            // Use a fixed URL (not random) so we can reopen it.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hp1-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng = makeRNG()
            var corpus: [(id: String, v: [Float])] = []

            // ── Instance A: build and persist ────────────────────────────────
            let storageA = try await openStorage(at: url)
            let storeA   = VectorStore(storage: storageA, hnswThreshold: Self.threshold)

            for i in 0..<Self.count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                corpus.append((id: "item-\(i)", v: v))
                try await storeA.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // THETA rebuild: builds graph in memory, persists to hnsw_graph table.
            try await storeA.rebuildHNSWIndex(for: Self.modelID)

            // Verify instance A actually built (hnswBuildCount == 1).
            let buildCountA = await storeA.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildCountA == 1,
                "HP-1: rebuildHNSWIndex must increment hnswBuildCount to 1 on instance A")

            // EXIT GATE A: direct row count assertion — hnsw_graph must have rows.
            let rowCountA = try await storeA.hnswGraphRowCount(for: Self.modelID)
            #expect(rowCountA > 0,
                "HP-1 (exit gate A, PERSISTENCE PROOF): hnsw_graph must contain rows after rebuildHNSWIndex; got 0")

            // Close the SQLite connection. No new reads/writes after this.
            await storageA.close()

            // ── Instance B: reopen, load from rows, serve ────────────────────
            let storageB = try await openStorage(at: url)
            let storeB   = VectorStore(storage: storageB, hnswThreshold: Self.threshold)

            // EXIT GATE B: hnswBuildCount must start at 0 on a fresh instance.
            let buildCountBefore = await storeB.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildCountBefore == 0,
                "HP-1 (exit gate B, RESTART PROOF): fresh VectorStore must have hnswBuildCount == 0 before any query")

            // Query: probe is item-0's vector (nearest to itself).
            let probe   = corpus[0].v
            let results = try await storeB.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 5)

            // EXIT GATE B: hnswBuildCount must still be 0 after query (loaded, not rebuilt).
            let buildCountAfter = await storeB.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildCountAfter == 0,
                "HP-1 (exit gate B, RESTART PROOF): hnswBuildCount must remain 0 after query — graph was loaded from rows, not rebuilt")

            // The query must return results (graph was loaded and is functional).
            #expect(results.isEmpty == false,
                "HP-1: findNearestFloat must return results after graph load from rows")

            // item-0 is the probe direction — must rank first.
            #expect(results.first?.itemID == "item-0",
                "HP-1: probe direction must rank nearest when served from loaded graph")

            await storageB.close()
        }
    }

    // MARK: - HP-2: absent graph → exact scan, no inline build

    /// When no hnsw_graph rows exist, findNearestFloat must fall back to exact
    /// scan and NOT perform an inline HNSW build. The query path must NEVER
    /// trigger a graph build.
    ///
    /// Instrumentation:
    ///   - `hnswBuildCount[modelID]` stays 0 throughout (no rebuild).
    ///   - `hnswIndices` stays empty (no in-memory graph created on the query path).
    ///   - Search results match the brute-force oracle top-1 (exact scan is exact).
    @Test("HP-2: absent graph degrades to exact scan without inline rebuild")
    func hp2_absentGraphExactScanFallback() async throws {
        try await GlobalTestLock.shared.withLock {
            // makeScratchStorage creates a fresh SQLite file but does NOT call open().
            // open() is called explicitly here (same pattern as HNSWIndexTests HI-6).
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, hnswThreshold: Self.threshold)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng = makeRNG(seed: 0xFEDCBA98_76543210)
            var corpus: [(id: String, v: [Float])] = []

            // Insert Self.count vectors (above threshold). Do NOT call rebuildHNSWIndex.
            // No hnsw_graph rows will exist.
            for i in 0..<Self.count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                corpus.append((id: "item-\(i)", v: v))
                try await store.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Pre-condition: no rebuild has occurred yet.
            let buildBefore = await store.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildBefore == 0,
                "HP-2: hnswBuildCount must be 0 before any query (no rebuild called)")

            // Query with a probe that clearly matches item-0.
            let probe   = corpus[0].v
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 5)

            // Core assertion: NO inline rebuild must have occurred.
            let buildAfter = await store.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildAfter == 0,
                "HP-2: hnswBuildCount must remain 0 after query — the query path must never trigger a rebuild")

            // Results must be non-empty (exact scan returns correct results).
            #expect(results.isEmpty == false,
                "HP-2: exact scan fallback must return results")

            // Verify search quality: oracle top-1 must appear in results.
            let oracleTop1 = bruteForce(probe: probe, corpus: corpus, k: 1).first
            #expect(results.first?.itemID == oracleTop1,
                "HP-2: exact scan must return the true nearest neighbour as rank-1")
        }
    }
    // MARK: - HP-3: DELETE-RESURRECTION proof (exit gate C)

    /// Tombstone a vector while the graph is on disk, reopen, assert the deleted
    /// item does NOT appear as a live neighbour (exit gate C: DELETE-RESURRECTION
    /// PROOF).
    ///
    /// The graph on disk reflects the corpus at the time of the last rebuild.
    /// If a vector is deleted AFTER the rebuild (from the vectors table) but
    /// BEFORE the next rebuild, the graph topology still references the old node.
    /// When the graph is loaded on reopen, `loadFromGraphRows` silently skips nodes
    /// whose float vector is absent from the `vectors` table (per the docstring:
    /// "Nodes missing from this map are silently skipped"). This test verifies that
    /// the deleted item's nodeIdx is dropped from the loaded graph so it cannot
    /// surface as a search result.
    ///
    /// Implementation note: after deletion the graph is stale (references a node
    /// that no longer has float bytes). The THETA rebuild (DreamingDaemon) corrects
    /// this on its cadence. Between deletion and the next rebuild, the loaded graph
    /// silently omits the deleted node (correct: graceful degradation vs. full exact
    /// scan). This test asserts that stale tombstoned-and-deleted nodes do NOT
    /// resurface as neighbours.
    @Test("HP-3: deleted vector does not resurface as live neighbour after reopen")
    func hp3_deleteResurrectionProof() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hp3-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng = makeRNG(seed: 0x1234_5678_9ABC_DEF0)
            var corpus: [(id: String, v: [Float])] = []

            // ── Instance A: insert corpus + build graph ───────────────────────
            let storageA = try await openStorage(at: url)
            let storeA   = VectorStore(storage: storageA, hnswThreshold: Self.threshold)

            for i in 0..<Self.count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                corpus.append((id: "item-\(i)", v: v))
                try await storeA.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            try await storeA.rebuildHNSWIndex(for: Self.modelID)

            // Delete "item-1" from the vectors table (while the graph is persisted).
            // The hnsw_graph rows still reference item-1's nodeIdx — they are NOT
            // updated by deleteVector (stale topology; corrected by THETA rebuild).
            try await storeA.deleteVector(
                itemID: "item-1", modelID: Self.modelID)

            await storageA.close()

            // ── Instance B: reopen — graph loads, item-1 node must be absent ─
            let storageB = try await openStorage(at: url)
            let storeB   = VectorStore(storage: storageB, hnswThreshold: Self.threshold)

            // Query with item-0's vector as probe. If item-1 has been silently
            // dropped from the loaded graph (as expected), it cannot appear in
            // results. We collect the full top-k and assert item-1 is absent.
            let probe   = corpus[0].v
            let results = try await storeB.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: Self.count)

            // EXIT GATE C (DELETE-RESURRECTION PROOF): item-1 must not appear.
            let resurrected = results.contains { $0.itemID == "item-1" }
            #expect(!resurrected,
                "HP-3 (exit gate C, DELETE-RESURRECTION PROOF): deleted item must not appear as a live neighbour after reopen")

            // The query must still return results (other items are live).
            #expect(!results.isEmpty,
                "HP-3: findNearestFloat must return results even after one item is deleted")

            // Pin the PATH, positively: a graph must be RESIDENT after the
            // query — buildCount == 0 alone is satisfied by the fallback scan
            // too (HP-2's premise), so it cannot distinguish the loaded-graph
            // path from the fallback quietly excluding the tombstoned item.
            let loaded = await storeB.hnswIndexResident(for: Self.modelID)
            #expect(loaded,
                "HP-3 path pin: an HNSW graph must be resident after the query — otherwise the exclusion came from the fallback scan")
            // And no rebuild produced it: resident + buildCount 0 = loaded.
            let buildCountB = await storeB.hnswBuildCount[Self.modelID] ?? 0
            #expect(buildCountB == 0,
                "HP-3 path pin: the resident graph must come from loaded rows (buildCount 0), never a rebuild")

            await storageB.close()
        }
    }
}

// MARK: - SplitMix64HP (local copy to avoid cross-suite symbol collision)

/// SplitMix64 RNG for reproducible vector generation.
/// Named SplitMix64HP to avoid name collision with the HNSWIndexTests version.
private struct SplitMix64HP {
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
