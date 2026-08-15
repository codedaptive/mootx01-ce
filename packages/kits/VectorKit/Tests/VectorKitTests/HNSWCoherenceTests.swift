// HNSWCoherenceTests.swift
//
// Regression tests for VH-01 Findings A, B, and C in VectorKit's HNSW layer.
//
// Finding A — stale HNSW cache returns deleted vectors:
//   After a vector is deleted from the VectorStore, the in-memory HNSW graph
//   must be evicted. Without the fix, hnswIndices[modelID] was left resident
//   while floatIndices[modelID] was cleared; the stale graph kept serving the
//   deleted item's raw bytes as if the deletion never happened.
//
// Finding B — entry-point tombstoned on upsert, recall suppressed:
//   HNSWIndex.insert() tombstones the existing node when upserting an item whose
//   ID is already in the graph. Without the fix, if that node was the current
//   entry point, the entry point remained pointing at a tombstoned node. Subsequent
//   search_layer calls silently skip the tombstoned seed → zero-result queries while
//   live_count > 0.
//
// Finding C — persisted hnsw_graph rows unvalidated before allocation:
//   loadFromGraphRows trusted `layer` and `neighboursBlob.count` from the SQLite
//   store. A crafted (or corrupt) row with an enormous `layer` value would size
//   per-node neighbour arrays beyond available memory. The fix adds a Phase-0
//   gate that rejects the whole graph if any row is out of bounds.
//
// These tests are designed to FAIL against the pre-fix code and PASS after the fix.
// Each test's docstring states the pre-fix failure mode.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import VectorKit

// MARK: - Suite: HC-A (Finding A — cache coherence)

/// Regression tests for Finding A: HNSW lane must be invalidated alongside the float lane.
///
/// Pre-fix failure mode (HC-A-1): after deleteVector, hnswIndices[modelID] was left
/// resident. findNearestFloat routed through the stale HNSW graph, which still held
/// item-1's raw vector bytes, returning it as a live result.
///
/// Pre-fix failure mode (HC-A-2): after destroyAllVectors, hnswIndices was not cleared,
/// leaving every model's graph resident and potentially returning results from a
/// logically-empty store.
@Suite("HC-A: HNSW cache coherence (VH-01 Finding A)")
struct HCACacheCoherenceTests {

    private static let modelID    = "hca-model"
    private static let dim        = 8
    private static let count      = 20   // above threshold (10)
    private static let threshold: UInt32 = 10

    private func openStorage(at url: URL) async throws -> any Storage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return storage
    }

    private func makeRNG(seed: UInt64 = 0xABCDEF01_23456789) -> SplitMix64HC {
        SplitMix64HC(state: seed)
    }

    private func randomVector(dim: Int, rng: inout SplitMix64HC) -> [Float] {
        var v = (0..<dim).map { _ in rng.nextFloat() }
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        for i in v.indices { v[i] /= norm }
        return v
    }

    /// HC-A-1: After rebuilding HNSW and then deleting a vector, findNearestFloat
    /// must NOT return the deleted item.
    ///
    /// Without the fix, hnswIndices[modelID] remained resident after deleteVector
    /// cleared only floatIndices[modelID]. The next findNearestFloat would route
    /// through the stale HNSW graph (which owned item-1's raw bytes) and return it.
    ///
    /// With the fix, _invalidateHNSWLane evicts hnswIndices[modelID] alongside
    /// floatIndices[modelID]. The next findNearestFloat reloads from hnsw_graph;
    /// _loadHNSWGraphIfPresent re-derives node bytes from the vectors table, so
    /// item-1's placeholder tombstone is excluded from the loaded graph.
    @Test("HC-A-1: deleted vector not returned after HNSW rebuild — cache invalidation gate")
    func hcA1_deletedVectorNotReturnedAfterRebuild() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hca1-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng = makeRNG()
            let storage = try await openStorage(at: url)
            let store   = VectorStore(storage: storage, hnswThreshold: Self.threshold)

            // Insert enough vectors to cross the threshold.
            for i in 0..<Self.count {
                var v = randomVector(dim: Self.dim, rng: &rng)
                // item-1 gets a distinctive vector so it could plausibly rank near
                // a natural probe if the stale HNSW graph serves it.
                if i == 1 { v = [Float](repeating: 1.0 / Float(Self.dim).squareRoot(), count: Self.dim) }
                try await store.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // THETA rebuild: builds the HNSW graph in memory and persists it to
            // the hnsw_graph table. After this call hnswIndices[modelID] is resident.
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Delete item-1. The fix: this call must evict hnswIndices[modelID]
            // alongside floatIndices[modelID] so the stale graph cannot serve item-1.
            try await store.deleteVector(itemID: "item-1", modelID: Self.modelID)

            // Probe near item-1's direction to maximise the chance it would appear
            // if the stale graph is still resident.
            let probe = [Float](repeating: 1.0 / Float(Self.dim).squareRoot(), count: Self.dim)
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: Self.count)

            // EXIT GATE: item-1 must NOT appear.
            let resurrected = results.contains { $0.itemID == "item-1" }
            #expect(!resurrected,
                "HC-A-1 (VH-01 Finding A REGRESSION): deleted item-1 must not appear in findNearestFloat results; the HNSW graph must be evicted on deleteVector")

            await storage.close()
        }
    }

    /// HC-A-2: After destroyAllVectors, findNearestFloat must return empty results.
    ///
    /// Without the fix, destroyAllVectors cleared floatIndices but not hnswIndices.
    /// A subsequent findNearestFloat would route through the still-resident HNSW graph,
    /// returning items from a logically-empty estate.
    ///
    /// With the fix, destroyAllVectors also clears hnswIndices, liveFloatCounts,
    /// hnswGraphDirty, AND deletes every hnsw_graph row from storage.
    @Test("HC-A-2: destroyAllVectors leaves no HNSW graph resident — full teardown gate")
    func hcA2_destroyAllVectorsLeavesNoGraph() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hca2-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng = makeRNG(seed: 0xDEAD_BEEF_1234_5678)
            let storage = try await openStorage(at: url)
            let store   = VectorStore(storage: storage, hnswThreshold: Self.threshold)

            for i in 0..<Self.count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Build the HNSW graph so it is resident in memory.
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Verify HNSW is resident (baseline).
            let resident = await store.hnswIndexResident(for: Self.modelID)
            #expect(resident, "HC-A-2 setup: HNSW must be resident after rebuildHNSWIndex")

            // Destroy ALL vectors (teardown path).
            try await store.destroyAllVectors()

            // The fix: findNearestFloat must return empty — HNSW evicted + rows deleted.
            let probe = randomVector(dim: Self.dim, rng: &rng)
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: Self.count)

            #expect(results.isEmpty,
                "HC-A-2 (VH-01 Finding A REGRESSION): findNearestFloat must return empty after destroyAllVectors; the HNSW graph must be fully torn down")

            await storage.close()
        }
    }
}

// MARK: - Suite: HC-B (Finding B — entry-point repair)

/// Regression tests for Finding B: HNSWIndex must call repairEntryPoint() immediately
/// after tombstoning an existing node via tombstone() or insert()-upsert.
///
/// Pre-fix failure mode: after tombstoning a node that was the graph's entry point,
/// entryPoint still pointed at the tombstoned node. search_layer entered at the
/// dead node, found no valid greedy hops, and returned zero results — recall
/// suppression while live_count > 0.
@Suite("HC-B: HNSW entry-point repair after tombstone (VH-01 Finding B)")
struct HCBEntryPointRepairTests {

    private static let modelID = "hcb-model"

    /// HC-B-1: Tombstone each node in sequence; after each operation, search must
    /// return only live nodes (non-empty until the last node is tombstoned).
    ///
    /// With three nodes (a, b, c), one of them is always the current entry point.
    /// The sequence: tombstone(a) → must return {b, c}; tombstone(b) → must return {c};
    /// tombstone(c) → must return {}.
    ///
    /// Pre-fix: whichever tombstone hits the entry point causes the next search to
    /// return empty (dead seed, no valid hops). The test catches this at the first
    /// assertion that fires after the entry-point tombstone.
    ///
    /// Post-fix: repairEntryPoint() immediately after each tombstone promotes the
    /// best remaining live node to entry point, so search always starts from a
    /// valid seed.
    @Test("HC-B-1: tombstone sequence never suppresses recall of live nodes")
    func hcB1_tombstoneSequenceNeverSuppressesRecall() async throws {
        let idx = HNSWIndex(seed: 42)

        // Insert three well-separated unit vectors.
        // Inserting in this order, "a" is the first node (index 0) and will be
        // the entry point if it receives the highest level (common with small graphs).
        await idx.insert(itemID: "a", modelID: Self.modelID, vector: [1, 0, 0])
        await idx.insert(itemID: "b", modelID: Self.modelID, vector: [0, 1, 0])
        await idx.insert(itemID: "c", modelID: Self.modelID, vector: [0, 0, 1])

        // Verify baseline: all three nodes are live and searchable.
        let baseline = try await idx.search(probe: [1, 0, 0], modelID: Self.modelID, k: 3)
        #expect(baseline.count >= 1, "HC-B-1 baseline: search must return at least one result before any tombstone")

        // ── Tombstone "a" — "b" and "c" must remain reachable ─────────────────
        await idx.tombstone(itemID: "a")
        let r1 = try await idx.search(probe: [0, 1, 0], modelID: Self.modelID, k: 3)
        #expect(!r1.isEmpty,
            "HC-B-1 (VH-01 Finding B REGRESSION): after tombstoning 'a', live nodes must still be reachable; entry-point repair must have promoted a live seed")
        #expect(!r1.map(\.itemID).contains("a"),
            "HC-B-1: tombstoned 'a' must not appear in search results")

        // ── Tombstone "b" — only "c" remains ──────────────────────────────────
        await idx.tombstone(itemID: "b")
        let r2 = try await idx.search(probe: [0, 0, 1], modelID: Self.modelID, k: 3)
        #expect(!r2.isEmpty,
            "HC-B-1 (VH-01 Finding B REGRESSION): after tombstoning 'a' and 'b', 'c' must still be reachable")
        #expect(r2.map(\.itemID) == ["c"],
            "HC-B-1: only 'c' is live — it must be the sole result")

        // ── Tombstone "c" — no live nodes remain ──────────────────────────────
        await idx.tombstone(itemID: "c")
        let r3 = try await idx.search(probe: [0, 0, 1], modelID: Self.modelID, k: 3)
        #expect(r3.isEmpty, "HC-B-1: all nodes tombstoned — search must return empty")
    }

    /// HC-B-2: Upsert (insert for an existing itemID) does not suppress recall.
    ///
    /// insert() tombstones the existing node when the itemID is already in the graph.
    /// At least one upsert in the sequence will tombstone the current entry point.
    /// Pre-fix: the entry point is left pointing at the newly-tombstoned node;
    /// search from that dead seed returns zero results.
    /// Post-fix: repairEntryPoint() called immediately after the tombstone inside
    /// insert() ensures a live entry point is always present.
    @Test("HC-B-2: upsert (insert for existing itemID) does not suppress recall")
    func hcB2_upsertDoesNotSuppressRecall() async throws {
        let idx = HNSWIndex(seed: 42)

        await idx.insert(itemID: "a", modelID: Self.modelID, vector: [1, 0, 0])
        await idx.insert(itemID: "b", modelID: Self.modelID, vector: [0, 1, 0])
        await idx.insert(itemID: "c", modelID: Self.modelID, vector: [0, 0, 1])

        // Upsert each item with a new vector. One of these upserts tombstones
        // the current entry point. The search after each upsert MUST be non-empty
        // because liveCount is always > 0 (the upserted item becomes a new live node).
        let upsertVectors: [(String, [Float])] = [
            ("a", [-1,  0,  0]),
            ("b", [ 0, -1,  0]),
            ("c", [ 0,  0, -1]),
        ]

        for (id, vec) in upsertVectors {
            await idx.insert(itemID: id, modelID: Self.modelID, vector: vec)
            let lc = await idx.liveCount
            #expect(lc >= 1, "HC-B-2 invariant: liveCount must be ≥ 1 after upserting \(id)")

            let results = try await idx.search(probe: [1, 0, 0], modelID: Self.modelID, k: 3)
            #expect(!results.isEmpty,
                "HC-B-2 (VH-01 Finding B REGRESSION): after upserting '\(id)', search must return non-empty results — entry-point repair must have maintained a live seed")
        }
    }
}

// MARK: - Suite: HC-C (Finding C — persisted row validation)

/// Regression tests for Finding C: loadFromGraphRows must validate every row
/// before any allocation is sized from untrusted persisted data.
///
/// Pre-fix failure mode: the `layer` field drove `count: maxLayer + 1` allocation
/// and `neighboursBlob.count` drove the decoded-array size, with no bounds check.
/// A row with layer=33 (> hnswMaxPersistedLayer=32) would silently load into the
/// graph with an over-sized neighbour array. A row with negative nodeIdx would
/// produce an array index trap. A misaligned blob would decode garbage neighbours.
///
/// Post-fix: Phase-0 gate checks every row before any allocation. One bad row
/// rejects the WHOLE graph (returns without loading). The index stays empty
/// (hasGraph → false) and the caller falls back to exact scan.
@Suite("HC-C: HNSW persisted row validation (VH-01 Finding C)")
struct HCCRowValidationTests {

    private static let modelID = "hcc-model"

    // ── HC-C-1: layer > hnswMaxPersistedLayer ─────────────────────────────────

    /// A row with layer = 33 (> hnswMaxPersistedLayer = 32) must cause the whole
    /// graph to be rejected. hasGraph must be false after the call.
    ///
    /// Pre-fix: the row was processed; `count: maxLayer + 1 = 34` was allocated
    /// (benign here, but the gate was absent). hasGraph would be true (wrong).
    /// Post-fix: Phase-0 gate fires → early return → hasGraph false.
    @Test("HC-C-1: row with layer > hnswMaxPersistedLayer rejects whole graph")
    func hcC1_hugeLevelRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0, 0, 0x80, 0x3f])  // 1.0f LE
        ]
        let badRow = HNSWIndex.GraphRow(
            nodeIdx:        0,
            nodeID:         "x",
            layer:          hnswMaxPersistedLayer + 1,  // 33 — one above the cap
            neighboursBlob: Data()
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-1 (VH-01 Finding C REGRESSION): a row with layer=\(hnswMaxPersistedLayer + 1) must be rejected; the Phase-0 gate must keep hasGraph false")
    }

    // ── HC-C-2: negative nodeIdx ───────────────────────────────────────────────

    /// A row with nodeIdx = -1 must cause the whole graph to be rejected.
    ///
    /// Pre-fix: the code used `Int32(rawNodeIdx)` without a non-negative guard;
    /// a negative nodeIdx would be used as an array subscript, causing a trap.
    /// Post-fix: Phase-0 gate rejects → hasGraph false.
    @Test("HC-C-2: row with negative nodeIdx rejects whole graph")
    func hcC2_negativeNodeIdxRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [:]
        let badRow = HNSWIndex.GraphRow(
            nodeIdx:        -1,          // negative — was an array-index trap pre-fix
            nodeID:         "x",
            layer:          0,
            neighboursBlob: Data()
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-2 (VH-01 Finding C REGRESSION): a row with nodeIdx=-1 must be rejected; the Phase-0 guard must keep hasGraph false")
    }

    // ── HC-C-3: blob length not divisible by 4 ────────────────────────────────

    /// A row whose neighboursBlob length is not a multiple of 4 bytes must be
    /// rejected. Int32 elements are 4 bytes; a 5-byte blob cannot contain a
    /// whole number of Int32 values — the last partial element is garbage.
    ///
    /// Pre-fix: decodeNeighbours read as many 4-byte chunks as fit, discarding
    /// the tail byte. No guard existed. hasGraph would be true (wrong).
    /// Post-fix: Phase-0 gate fires → hasGraph false.
    @Test("HC-C-3: row with misaligned blob (len % 4 != 0) rejects whole graph")
    func hcC3_misalignedBlobRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0, 0, 0x80, 0x3f])
        ]
        let badRow = HNSWIndex.GraphRow(
            nodeIdx:        0,
            nodeID:         "x",
            layer:          0,
            neighboursBlob: Data([0, 0, 0, 0, 0xFF])  // 5 bytes — not divisible by 4
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-3 (VH-01 Finding C REGRESSION): a row with 5-byte blob (misaligned) must be rejected; hasGraph must be false")
    }

    // ── HC-C-4: blob length exceeds hnswM0 * 4 ────────────────────────────────

    /// A row whose neighboursBlob encodes more than hnswM0 neighbours must be
    /// rejected. Layer 0 has a maximum of hnswM0 = 32 connections; any more is
    /// structurally invalid and could drive unbounded decode in a naive
    /// implementation.
    ///
    /// Pre-fix: decodeNeighbours decoded all (ptr.count / 4) neighbours without
    /// an upper bound. hasGraph would be true (wrong).
    /// Post-fix: Phase-0 gate fires → hasGraph false.
    @Test("HC-C-4: row with oversized blob (len > hnswM0 * 4) rejects whole graph")
    func hcC4_oversizedBlobRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0, 0, 0x80, 0x3f])
        ]
        // hnswM0 = 32 → max blob = 32 * 4 = 128 bytes. Use 132 bytes (33 entries).
        let oversizedBlob = Data(repeating: 0, count: (hnswM0 + 1) * 4)
        let badRow = HNSWIndex.GraphRow(
            nodeIdx:        0,
            nodeID:         "x",
            layer:          0,
            neighboursBlob: oversizedBlob
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-4 (VH-01 Finding C REGRESSION): a row with \((hnswM0 + 1) * 4)-byte blob (>\(hnswM0 * 4) max) must be rejected; hasGraph must be false")
    }
}

// MARK: - SplitMix64HC (local copy — no cross-suite collision)

/// SplitMix64 RNG for reproducible vector generation.
/// Named SplitMix64HC to avoid symbol collision with other test suite copies.
private struct SplitMix64HC {
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
