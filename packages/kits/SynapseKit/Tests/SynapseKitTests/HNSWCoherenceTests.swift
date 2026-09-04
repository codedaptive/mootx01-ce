// HNSWCoherenceTests.swift
//
// Regression tests for VH-01 Findings A, B, and C in SynapseKit's HNSW layer.
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
// F1 — loadFromGraphRows 'continue'd on a node whose float vector was gone,
//   shifting every later compact index down by one and mis-wiring every neighbour
//   edge. Fix: insert a placeholder tombstone so compact indices hold.
//
// F7 — vectorStride was derived from nodes.first, which after the F1 fix can be
//   the placeholder tombstone with zero bytes → stride 0 → search throws
//   invalidPayload → total recall suppression. Fix: derive stride from the first
//   non-tombstoned node.
//
// NOTE ON GENERATION FIELD (generation: 0):
//   All GraphRow literals and loadFromGraphRows calls in this file use generation=0
//   and expectedGeneration=0. Generation 0 is the pre-shadow-swap serving generation
//   for any estate that has never run a shadow swap (VEC-SHADOWSWAP-01, 0332).
//   These engine-level fixtures are generation-agnostic — they test graph topology
//   and loading semantics, not generation filtering, so 0 is the correct value for
//   all fixtures here.
//
// These tests are designed to FAIL against the pre-fix code and PASS after the fix.
// Each test's docstring states the pre-fix failure mode.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import SynapseKit

// Test-local mirror of the production constant `hnswMaxPersistedLayer`
// (Sources/SynapseKit/Engine/HNSWIndex.swift), which the VH-01 Finding C fix
// introduced. The pre-fix tree does not declare it, so this file could not be
// compiled against a pre-fix base — and compiling it against a pre-fix base is
// how every gate in this file is proved to discriminate. The mirror keeps the
// measurement repeatable.
//
// Drift is caught, not silent: if production ever raises the cap above 32, a
// layer of 33 becomes valid, the graph loads, and HC-C-1's `!hasGraph`
// expectation fails loudly on the next run.
private let testHnswMaxPersistedLayer: Int = 32

// MARK: - Suite: HC-A (Finding A — cache coherence)

/// Regression tests for Finding A: HNSW lane must be invalidated alongside the float lane.
///
/// Pre-fix failure mode (HC-A-1): after deleteVector, hnswIndices[modelID] was left
/// resident. findNearestFloat routed through the stale HNSW graph, which still held
/// item-1's raw vector bytes, returning it as a live result.
///
/// Pre-fix failure mode (HC-A-2): after destroyAllVectors, hnswIndices was not cleared
/// and hnsw_graph rows were not deleted, leaving every model's graph topology persisted.
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

    /// HC-A-2: After destroyAllVectors, the hnsw_graph table must have zero rows.
    ///
    /// Without the fix, destroyAllVectors cleared floatIndices but not hnswIndices,
    /// and did not delete hnsw_graph rows from storage. The persisted graph topology
    /// remained on disk even though every vector was gone.
    ///
    /// With the fix, destroyAllVectors also calls hnswIndices.removeAll() and deletes
    /// every hnsw_graph row, so the storage is fully consistent with the empty vectors
    /// table.
    ///
    /// Assertion: hnswGraphRowCount == 0 after destroyAllVectors. This assertion
    /// discriminates because pre-fix code leaves hnsw_graph rows intact; the
    /// findNearestFloat emptiness check cannot distinguish "rows deleted" from
    /// "exact scan returned empty because vectors table is empty".
    @Test("HC-A-2: destroyAllVectors deletes all hnsw_graph rows — durable teardown gate")
    func hcA2_destroyAllVectorsDeletesGraphRows() async throws {
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

            // Build the HNSW graph so it is resident in memory and on disk.
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Baseline: confirm rows were persisted.
            let rowsBefore = try await store.hnswGraphRowCount(for: Self.modelID)
            #expect(rowsBefore > 0, "HC-A-2 setup: hnsw_graph must have rows after rebuildHNSWIndex")

            // Destroy ALL vectors (teardown path).
            try await store.destroyAllVectors()

            // EXIT GATE: hnsw_graph rows must be physically deleted from storage.
            // Pre-fix: destroyAllVectors does not delete hnsw_graph rows → count > 0 → FAILS.
            // Post-fix: rows deleted → count == 0 → PASSES.
            let rowsAfter = try await store.hnswGraphRowCount(for: Self.modelID)
            #expect(rowsAfter == 0,
                "HC-A-2 (VH-01 Finding A REGRESSION): destroyAllVectors must delete all hnsw_graph rows; pre-fix code leaves the persisted graph topology intact on disk even after the vectors table is empty.")

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
/// A row with layer=33 (> testHnswMaxPersistedLayer=32) would silently load into the
/// graph with an over-sized neighbour array. A row with negative nodeIdx would
/// produce an array index trap. A misaligned blob would decode garbage neighbours.
///
/// Post-fix: Phase-0 gate checks every row before any allocation. One bad row
/// rejects the WHOLE graph (returns without loading). The index stays empty
/// (hasGraph → false) and the caller falls back to exact scan.
@Suite("HC-C: HNSW persisted row validation (VH-01 Finding C)")
struct HCCRowValidationTests {

    private static let modelID = "hcc-model"

    // ── HC-C-1: layer > testHnswMaxPersistedLayer ─────────────────────────────────

    /// A row with layer = 33 (> testHnswMaxPersistedLayer = 32) must cause the whole
    /// graph to be rejected. hasGraph must be false after the call.
    ///
    /// Pre-fix: the row was processed; `count: maxLayer + 1 = 34` was allocated
    /// (benign here, but the gate was absent). hasGraph would be true (wrong).
    /// Post-fix: Phase-0 gate fires → early return → hasGraph false.
    @Test("HC-C-1: row with layer > testHnswMaxPersistedLayer rejects whole graph")
    func hcC1_hugeLevelRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0, 0, 0x80, 0x3f])  // 1.0f LE
        ]
        let badRow = HNSWIndex.GraphRow(
            nodeIdx:        0,
            nodeID:         "x",
            layer:          testHnswMaxPersistedLayer + 1,  // 33 — one above the cap
            neighboursBlob: Data(),
            generation:     0  // pre-shadow-swap serving generation; fixture is generation-agnostic
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID,
                                    expectedGeneration: 0)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-1 (VH-01 Finding C REGRESSION): a row with layer=\(testHnswMaxPersistedLayer + 1) must be rejected; the Phase-0 gate must keep hasGraph false")
    }

    // ── HC-C-2: negative nodeIdx alongside valid rows ─────────────────────────

    /// A row with nodeIdx = -1, present alongside two valid rows, must cause the
    /// whole graph to be rejected. hasGraph must be false after the call.
    ///
    /// Pre-fix: no Phase-0 gate existed. The negative-nodeIdx row had no entry
    /// in nodeBytes so the pre-fix `continue` skipped it; the two valid rows (0
    /// and 1) loaded successfully → hasGraph became true (wrong).
    /// Post-fix: Phase-0 gate fires on the nodeIdx=-1 row (`row.nodeIdx >= 0`
    /// fails) → early return → the whole graph is rejected → hasGraph false.
    ///
    /// The fixture uses valid nodeBytes for nodeIdx=0 and nodeIdx=1 so that the
    /// pre-fix path would load them and set hasGraph=true, making the gate
    /// discriminating. An empty nodeBytes[:] fixture cannot distinguish pre-fix
    /// from post-fix because both paths would leave hasGraph=false via different
    /// mechanisms (the pre-fix `continue` on every row vs. the post-fix Phase-0 reject).
    @Test("HC-C-2: negative nodeIdx row alongside valid rows rejects whole graph (Finding C discriminating)")
    func hcC2_negativeNodeIdxRejected() async throws {
        let idx = HNSWIndex(seed: 42)
        // Valid nodeBytes for nodeIdx=0 and nodeIdx=1 ensure pre-fix code loads
        // those nodes and sets hasGraph=true; post-fix the Phase-0 gate fires first.
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0x00, 0x00, 0x80, 0x3f]),  // 1.0f LE
            1: ("y", [0x00, 0x00, 0x00, 0x3f]),  // 0.5f LE
        ]
        let rows = [
            HNSWIndex.GraphRow(
                nodeIdx:        -1,          // negative — Phase-0 must reject whole graph
                nodeID:         "bad",
                layer:          0,
                neighboursBlob: Data(),
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        0,
                nodeID:         "x",
                layer:          0,
                neighboursBlob: Data(),
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        1,
                nodeID:         "y",
                layer:          0,
                neighboursBlob: Data(),
                generation:     0
            ),
        ]
        await idx.loadFromGraphRows(rows, nodeBytes: nodeBytes, modelID: Self.modelID,
                                    expectedGeneration: 0)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-2 (VH-01 Finding C REGRESSION): a nodeIdx=-1 row alongside valid rows must reject the whole graph; pre-fix loaded the valid rows and set hasGraph=true; post-fix Phase-0 gate fires and rejects everything.")
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
            neighboursBlob: Data([0, 0, 0, 0, 0xFF]),  // 5 bytes — not divisible by 4
            generation:     0
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID,
                                    expectedGeneration: 0)

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
            neighboursBlob: oversizedBlob,
            generation:     0
        )
        await idx.loadFromGraphRows([badRow], nodeBytes: nodeBytes, modelID: Self.modelID,
                                    expectedGeneration: 0)

        let hasGraph = await idx.hasGraph
        #expect(!hasGraph,
            "HC-C-4 (VH-01 Finding C REGRESSION): a row with \((hnswM0 + 1) * 4)-byte blob (>\(hnswM0 * 4) max) must be rejected; hasGraph must be false")
    }
}

// MARK: - Suite: HC-D (Discriminating tests for F7, F2, F3, F1)

/// Discriminating regression tests that FAIL against pre-fix code in one specific
/// code path and PASS after the corresponding fix. These complement HC-A through HC-C
/// by covering the exact failure modes that required the F7 (stride skip tombstones),
/// F2b (reset before empty-rows guard), F3 (store-layer row validation), and F1
/// (tombstone placeholder endpoint-identity) fixes.
@Suite("HC-D: Discriminating tests for F7, F2, F3, F1 (VH-01)")
struct HCDDiscriminatingTests {

    private static let modelID    = "hcd-model"
    private static let hnswModel  = "hcd-hnsw"
    private static let dim        = 8
    private static let count      = 20
    private static let threshold: UInt32 = 10

    private func openStorage(at url: URL) async throws -> any Storage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return storage
    }

    private func makeRNG(seed: UInt64 = 0xABCD_1234_EF56_7890) -> SplitMix64HC {
        SplitMix64HC(state: seed)
    }

    private func randomVector(dim: Int, rng: inout SplitMix64HC) -> [Float] {
        var v = (0..<dim).map { _ in rng.nextFloat() }
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        for i in v.indices { v[i] /= norm }
        return v
    }

    // ── HC-D-1: F7 — tombstone at compact index 0 does not suppress search ────

    /// HC-D-1: When the first persisted graph node (compact index 0) was deleted
    /// from the `vectors` table before a reload, `loadFromGraphRows` must derive
    /// `vectorStride` from the first non-tombstoned node (F7).
    ///
    /// Without the F7 fix (with F1 in place): the tombstone placeholder at compact
    /// index 0 has `vectorBytes == []`; `vectorStride = nodes.first?.vectorBytes.count`
    /// evaluates to `Optional(0)`. `search()` guards on `expectedDim == 0` and
    /// throws `invalidPayload`, suppressing all recall while live nodes exist.
    ///
    /// With the F7 fix: stride is derived from the first non-tombstoned node →
    /// search returns live nodes correctly.
    ///
    /// NOTE — this test gates F7 only. At BASE_A (pre-F1/F7), loadFromGraphRows
    /// uses 'continue' on missing nodeBytes entries, so nodes.first is always a
    /// live node with real bytes; vectorStride is computed correctly and search
    /// returns results. The gate only fires at the intermediate state where F1 is
    /// applied (tombstone inserted) but F7 is not (stride still reads nodes.first).
    @Test("HC-D-1: tombstone at compact index 0 — search returns live nodes (F7 discriminating)")
    func hcD1_tombstoneAtIndexZeroDoesNotSuppressSearch() async throws {
        let idx     = HNSWIndex(seed: 42)
        let modelID = "hcd1-model"

        // nodeIdx=0 is absent from nodeBytes: it was deleted from `vectors` before
        // the reload, so `loadFromGraphRows` must insert a tombstone placeholder at
        // compact index 0 (VH-01 F1) rather than `continue`ing (which would shift
        // later indices and mis-wire neighbour edges).
        //
        // nodeIdx=1 and nodeIdx=2 are live 1-dimensional float vectors:
        //   nodeIdx=1 → "live-b" → bytes [0x00, 0x00, 0x80, 0x3f] = 1.0f LE
        //   nodeIdx=2 → "live-c" → bytes [0x00, 0x00, 0x00, 0x3f] = 0.5f LE
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            1: ("live-b", [0x00, 0x00, 0x80, 0x3f]),
            2: ("live-c", [0x00, 0x00, 0x00, 0x3f]),
        ]
        // Neighbour blobs: little-endian Int32 arrays in old nodeIdx space.
        // loadFromGraphRows remaps them through oldToNew before wiring.
        let rows = [
            HNSWIndex.GraphRow(
                nodeIdx:        0,
                nodeID:         "deleted-a",
                layer:          0,
                // Neighbours point to nodeIdx=1 and nodeIdx=2 (old space).
                neighboursBlob: Data([0x01, 0x00, 0x00, 0x00,
                                      0x02, 0x00, 0x00, 0x00]),
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        1,
                nodeID:         "live-b",
                layer:          0,
                neighboursBlob: Data([0x00, 0x00, 0x00, 0x00]),  // neighbour: nodeIdx=0
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        2,
                nodeID:         "live-c",
                layer:          0,
                neighboursBlob: Data([0x00, 0x00, 0x00, 0x00]),  // neighbour: nodeIdx=0
                generation:     0
            ),
        ]

        await idx.loadFromGraphRows(rows, nodeBytes: nodeBytes, modelID: modelID,
                                    expectedGeneration: 0)

        let hasGraph = await idx.hasGraph
        #expect(hasGraph, "HC-D-1: graph must load successfully even with a tombstone at compact index 0")

        // Pre-fix F7: vectorStride = nodes.first?.vectorBytes.count = 0 (tombstone)
        //   → search() throws invalidPayload("expected 0") → all recall suppressed.
        // Post-fix F7: stride = nodes.first(where: { !$0.tombstoned })?.vectorBytes.count
        //   = 4 bytes / 4 = 1 Float → search proceeds correctly.
        let results = try await idx.search(probe: [1.0], modelID: modelID, k: 5)

        #expect(!results.isEmpty,
            "HC-D-1 F7 REGRESSION: search must return live nodes when compact index 0 is a tombstone placeholder. Pre-fix: vectorStride=0 → invalidPayload thrown.")
        #expect(!results.map(\.itemID).contains("deleted-a"),
            "HC-D-1: the placeholder tombstone must not appear in search results")
    }

    // ── HC-D-2: F2b — reload with empty rows resets entryPoint ───────────────────

    /// HC-D-2: After loading a valid graph, calling `loadFromGraphRows([])` must reset
    /// all state (entryPoint → nil, nodes cleared) so that `hasGraph` returns false.
    ///
    /// Without the F2b fix: `guard !rows.isEmpty else { return }` fired before any
    /// state reset. Calling with empty rows left entryPoint and nodes intact from the
    /// prior load → `hasGraph` stayed true (stale graph survived an explicit empty reload).
    ///
    /// With the F2b fix: the reset block (nodes.removeAll, entryPoint = nil, etc.) runs
    /// BEFORE the empty-rows guard. An empty reload now produces a clean empty index.
    @Test("HC-D-2: reload with empty rows resets entryPoint to nil — hasGraph false (F2b discriminating)")
    func hcD2_emptyReloadClearsState() async throws {
        let idx     = HNSWIndex(seed: 42)
        let modelID = "hcd2-model"

        // Step 1: Load a valid 2-node graph.
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0x00, 0x00, 0x80, 0x3f]),
            1: ("y", [0x00, 0x00, 0x00, 0x3f]),
        ]
        let rows = [
            HNSWIndex.GraphRow(nodeIdx: 0, nodeID: "x", layer: 0,
                               neighboursBlob: Data([0x01, 0x00, 0x00, 0x00]),
                               generation: 0),
            HNSWIndex.GraphRow(nodeIdx: 1, nodeID: "y", layer: 0,
                               neighboursBlob: Data([0x00, 0x00, 0x00, 0x00]),
                               generation: 0),
        ]
        await idx.loadFromGraphRows(rows, nodeBytes: nodeBytes, modelID: modelID,
                                    expectedGeneration: 0)

        let hasBefore = await idx.hasGraph
        #expect(hasBefore, "HC-D-2 setup: graph must be resident after loading valid rows")

        // Step 2: Reload with zero rows.
        // Pre-fix F2b: `guard !rows.isEmpty else { return }` fires without resetting
        //   state → entryPoint and nodes survive → hasGraph stays true (wrong).
        // Post-fix F2b: reset block runs before guard → entryPoint = nil → hasGraph false.
        await idx.loadFromGraphRows([], nodeBytes: [:], modelID: modelID,
                                    expectedGeneration: 0)

        let hasAfter = await idx.hasGraph
        #expect(!hasAfter,
            "HC-D-2 F2b REGRESSION: loadFromGraphRows([]) must reset all state; hasGraph must be false after an empty reload on a previously-populated index.")
    }

    // ── HC-D-3: Finding B — two-load sequence then full tombstone, no crash ───────

    /// HC-D-3: After loading a 3-node graph and then reloading with a smaller 1-node
    /// graph, tombstoning the remaining node must result in hasGraph=false.
    ///
    /// MEASURED AGAINST BASE_A (7265a1834): this gate FAILS at BASE_A for Finding B
    /// reasons. BASE_A's tombstone() marks nodes dead without calling repairEntryPoint().
    /// After tombstoning "x", entryPoint still refers to it → hasGraph stays true.
    /// In the VH-01 fixed code, tombstone() calls repairEntryPoint(), which finds no
    /// live nodes and sets entryPoint=nil → hasGraph=false.
    ///
    /// The two-load sequence (3-node → 1-node) exercises the state-reset path (F2b),
    /// but the discriminating assertion is identical to HC-B-1/HC-B-2: tombstone must
    /// trigger entry-point repair. BASE_A lacks that repair in tombstone().
    ///
    /// F2a content (the repairEntryPoint bounds guard) is NOT gated by this test:
    /// with F2b in place, loadFromGraphRows resets state before every reload, so
    /// there is no code path that leaves a stale out-of-range entryPoint for
    /// repairEntryPoint to encounter. F2a is unreachable once F2b resets state.
    ///
    /// With the fix: second load resets state and rebuilds with 1 node; tombstone("x")
    /// triggers repair → entryPoint=nil → hasGraph=false.
    @Test("HC-D-3: two-load sequence then tombstone all — hasGraph false (Finding B discriminating; F2a unreachable with F2b in place)")
    func hcD3_twoLoadSequenceThenTombstoneAllIsSafe() async throws {
        let idx     = HNSWIndex(seed: 42)
        let modelID = "hcd3-model"

        // Step 1: Load a 3-node graph.
        let bytes3: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("a", [0x00, 0x00, 0x80, 0x3f]),
            1: ("b", [0x00, 0x00, 0x00, 0x3f]),
            2: ("c", [0x00, 0x00, 0x80, 0x3e]),  // 0.25f LE
        ]
        let rows3 = [
            HNSWIndex.GraphRow(nodeIdx: 0, nodeID: "a", layer: 0,
                               neighboursBlob: Data([0x01, 0x00, 0x00, 0x00]),
                               generation: 0),
            HNSWIndex.GraphRow(nodeIdx: 1, nodeID: "b", layer: 0,
                               neighboursBlob: Data([0x00, 0x00, 0x00, 0x00]),
                               generation: 0),
            HNSWIndex.GraphRow(nodeIdx: 2, nodeID: "c", layer: 0,
                               neighboursBlob: Data([0x00, 0x00, 0x00, 0x00]),
                               generation: 0),
        ]
        await idx.loadFromGraphRows(rows3, nodeBytes: bytes3, modelID: modelID,
                                    expectedGeneration: 0)
        let hasBefore = await idx.hasGraph
        #expect(hasBefore, "HC-D-3 setup: 3-node graph must be resident after first load")

        // Step 2: Reload with a 1-node graph.
        // F2b ensures the second load resets all state (nodes cleared, entryPoint=nil)
        // before processing the new rows. Without F2b, the 1-node graph would be
        // appended to the existing 3-node graph rather than replacing it.
        let bytes1: [Int32: (itemID: String, bytes: [UInt8])] = [
            0: ("x", [0x00, 0x00, 0x80, 0x3f]),
        ]
        let rows1 = [
            HNSWIndex.GraphRow(nodeIdx: 0, nodeID: "x", layer: 0,
                               neighboursBlob: Data(),
                               generation: 0),
        ]
        await idx.loadFromGraphRows(rows1, nodeBytes: bytes1, modelID: modelID,
                                    expectedGeneration: 0)
        let hasAfterReload = await idx.hasGraph
        #expect(hasAfterReload, "HC-D-3: 1-node graph must be resident after second load")

        // Step 3: Tombstone the only live node.
        // Post-fix (Finding B): tombstone() calls repairEntryPoint() → no live nodes →
        //   entryPoint=nil → hasGraph=false.
        // Pre-fix (BASE_A): tombstone() only marks the node dead, does not call
        //   repairEntryPoint() → entryPoint still set to the dead node → hasGraph=true.
        await idx.tombstone(itemID: "x")
        let hasFinal = await idx.hasGraph
        #expect(!hasFinal,
            "HC-D-3 Finding B REGRESSION: after tombstoning the only node, hasGraph must be false. Pre-fix tombstone() skips repairEntryPoint(), leaving entryPoint set to the now-dead node.")
    }

    // ── HC-D-4: F3 store-layer — one corrupt hnsw_graph row rejects the whole graph

    /// HC-D-4: Verifies the F3 fix at the STORE layer (VectorStore._loadHNSWGraphIfPresent).
    ///
    /// Pre-fix F3: the decode loop used `continue` on a bad row — invalid rows were
    ///   silently skipped and the remaining valid rows formed a partial HNSW graph.
    ///   `hnswIndexResident` would return true (wrong, partial graph was loaded).
    ///
    /// Post-fix F3: the decode loop uses `return` on any invalid row — one bad row
    ///   abandons the WHOLE load. `hnswIndexResident` stays false; findNearestFloat
    ///   falls back to exact scan and still returns correct results.
    ///
    /// This test targets the STORE layer, not the engine layer (HC-C suite). The
    /// bad row is written directly to the hnsw_graph SQLite table so that the
    /// store-layer decode path is exercised on reload.
    @Test("HC-D-4: one corrupt hnsw_graph row at store layer rejects whole graph → exact scan fallback (F3 discriminating)")
    func hcD4_storeLayerCorruptRowFallsBackToExactScan() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hcd4-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var rng  = makeRNG(seed: 0xD4_F3_AB_CD_12_34_56_78)
            let storage = try await openStorage(at: url)
            let store   = VectorStore(storage: storage, hnswThreshold: Self.threshold)

            // Insert enough vectors to cross the HNSW threshold.
            for i in 0..<Self.count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.hnswModel, modelVersion: "1",
                    filedAt: now
                )
            }

            // THETA rebuild: persists all nodes to the hnsw_graph table.
            try await store.rebuildHNSWIndex(for: Self.hnswModel)

            // Poison: insert one bad hnsw_graph row directly into storage.
            // node_idx=99999 avoids primary-key conflict with the valid rows [0..19].
            // layer = testHnswMaxPersistedLayer + 1 (= 33) triggers the F3 bounds check
            // at the store-layer decode loop: rawLayer <= testHnswMaxPersistedLayer fails →
            // whole graph load abandoned.
            _ = try await storage.rowStore.insert(
                table: "hnsw_graph",
                values: [
                    "model_id":   .text(Self.hnswModel),
                    "node_idx":   .int(Int64(99_999)),
                    "node_id":    .text("_poison_node_"),
                    "layer":      .int(Int64(testHnswMaxPersistedLayer + 1)),
                    "neighbours": .blob(Data()),
                    "generation": .int(0),
                ]
            )

            // deleteVector evicts the resident HNSW lane for hnswModel without
            // deleting hnsw_graph rows. The next findNearestFloat must reload from
            // hnsw_graph — where it will encounter the poison row.
            try await store.deleteVector(itemID: "item-0", modelID: Self.hnswModel)

            // Probe near item-0's direction to maximise the HNSW-vs-exact-scan
            // observable difference.
            let probe = randomVector(dim: Self.dim, rng: &rng)
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.hnswModel, limit: Self.count)

            // Post-fix F3: poison row → whole graph rejected → hnswIndices stays nil →
            //   hnswIndexResident = false → exact scan used.
            // Pre-fix F3: poison row skipped with `continue` → partial graph loaded →
            //   hnswIndexResident = true (wrong).
            let resident = await store.hnswIndexResident(for: Self.hnswModel)
            #expect(!resident,
                "HC-D-4 F3 REGRESSION: the poison hnsw_graph row (layer=\(testHnswMaxPersistedLayer + 1)) must cause the WHOLE graph load to be abandoned at the store layer. Pre-fix: `continue` silently skips the bad row and loads a partial graph (resident=true). Post-fix: `return` rejects the whole load (resident=false).")

            // Exact scan must still return non-empty results (count − 1 items remain).
            #expect(!results.isEmpty,
                "HC-D-4: exact scan fallback must return results from the remaining \(Self.count - 1) items")
            #expect(!results.map(\.itemID).contains("item-0"),
                "HC-D-4: the deleted item-0 must not appear in exact scan results")

            await storage.close()
        }
    }

    // ── HC-D-5: F1 — endpoint identity after tombstone at compact index 0 ─────

    /// HC-D-5: After a node's float vector is deleted (missing from nodeBytes),
    /// every surviving node's neighbour compact index must resolve to the correct
    /// itemID — no self-loops and no dangling edges.
    ///
    /// This gates VH-01 F1 (the tombstone-placeholder fix) at the ENDPOINT-IDENTITY
    /// level, not the liveness level. Pre-fix, loadFromGraphRows used 'continue' on
    /// a missing nodeBytes entry, shifting every later compact index down by one.
    /// The graph was functionally live (search still answered), but neighbour wiring
    /// was corrupted: live-c's neighbour pointed to itself (self-loop) and live-b's
    /// neighbour pointed past the end of the array (dangling).
    ///
    /// Fixture verification (run graphRows() and check neighbour-to-itemID resolution):
    ///   nodeBytes: {1: "live-b", 2: "live-c"} — nodeIdx=0 ("deleted-a") absent.
    ///   row topology: 0→[1,2], 1→[2], 2→[1].
    ///
    ///   POST-FIX: nodes=[tombstone, live-b, live-c].
    ///     graphRows() emits: live-b at compact 1 (neighbour 2 → "live-c" ✓),
    ///                        live-c at compact 2 (neighbour 1 → "live-b" ✓).
    ///
    ///   PRE-FIX (continue): nodes=[live-b, live-c].
    ///     oldToNew={0→0,1→1,2→2}; live-b's blob remapped: old=2→new=2 (dangling,
    ///     array size=2). live-c's blob remapped: old=1→new=1 (self-loop).
    ///     graphRows() emits: live-b at compact 0 (neighbour 2 → dangling),
    ///                        live-c at compact 1 (neighbour 1 → "live-c" self-loop).
    @Test("HC-D-5: F1 endpoint identity — neighbours resolve to correct itemIDs after tombstone at compact index 0 (F1 discriminating)")
    func hcD5_endpointIdentityAfterTombstoneAtIndexZero() async throws {
        let idx     = HNSWIndex(seed: 42)
        let modelID = "hcd5-model"

        // nodeIdx=0 ("deleted-a") has NO nodeBytes entry — its float vector was
        // deleted from the vectors table before reload. loadFromGraphRows must
        // insert a tombstone placeholder at compact index 0 (F1) so that
        // subsequent compact indices are not shifted.
        let nodeBytes: [Int32: (itemID: String, bytes: [UInt8])] = [
            1: ("live-b", [0x00, 0x00, 0x80, 0x3f]),  // 1.0f LE, dim=1
            2: ("live-c", [0x00, 0x00, 0x00, 0x3f]),  // 0.5f LE, dim=1
        ]

        // Row topology: nodeIdx=1 names nodeIdx=2 as neighbour; nodeIdx=2 names
        // nodeIdx=1. These blobs encode old-nodeIdx-space values; loadFromGraphRows
        // remaps them through oldToNew to the new compact space.
        //
        // Post-fix compact numbering: tombstone=0, live-b=1, live-c=2.
        //   live-b blob [2] → old=2 → new=2 → "live-c"  ✓
        //   live-c blob [1] → old=1 → new=1 → "live-b"  ✓
        //
        // Pre-fix compact numbering (continue shifts everything):
        //   oldToNew={0→0,1→1,2→2} — built from ALL rows including deleted-a.
        //   live-b lands at array[0] (continue skipped deleted-a).
        //   live-b blob [2] → old=2 → new=2 → dangling (array size=2).
        //   live-c lands at array[1].
        //   live-c blob [1] → old=1 → new=1 → "live-c" (self-loop).
        let rows = [
            HNSWIndex.GraphRow(
                nodeIdx:        0,
                nodeID:         "deleted-a",
                layer:          0,
                neighboursBlob: Data([0x01, 0x00, 0x00, 0x00,
                                      0x02, 0x00, 0x00, 0x00]),  // neighbours [1, 2]
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        1,
                nodeID:         "live-b",
                layer:          0,
                neighboursBlob: Data([0x02, 0x00, 0x00, 0x00]),  // neighbour [2]
                generation:     0
            ),
            HNSWIndex.GraphRow(
                nodeIdx:        2,
                nodeID:         "live-c",
                layer:          0,
                neighboursBlob: Data([0x01, 0x00, 0x00, 0x00]),  // neighbour [1]
                generation:     0
            ),
        ]

        await idx.loadFromGraphRows(rows, nodeBytes: nodeBytes, modelID: modelID,
                                    expectedGeneration: 0)

        // Observe the compact graph topology via graphRows(). Tombstoned nodes are
        // excluded from the output; only live nodes appear, with their post-load
        // compact indices and neighbour blobs.
        let emitted = await idx.graphRows()

        // Two live nodes must be emitted (the tombstone at compact 0 is excluded).
        #expect(emitted.count == 2,
            "HC-D-5 F1: graphRows() must emit exactly 2 live nodes; the tombstone placeholder must not appear in the output.")

        // Build compact-index → itemID map from emitted rows.
        let compactToItemID: [Int32: String] = Dictionary(
            uniqueKeysWithValues: emitted.map { ($0.nodeIdx, $0.nodeID) }
        )

        // Verify endpoint identity: every live node's neighbour must resolve to a
        // REAL other node — no self-loops, no dangling compact indices.
        //
        // Pre-fix failure (F1 REGRESSION): live-c's neighbour resolves to "live-c"
        // (self-loop) and live-b's neighbour index 2 has no entry in the map (dangling).
        // Post-fix: both resolve correctly to the other live node.
        for row in emitted {
            let neighbours = row.decodeNeighbours()
            for neighbourIdx in neighbours {
                guard let resolvedID = compactToItemID[neighbourIdx] else {
                    #expect(Bool(false),
                        "HC-D-5 F1 REGRESSION: \(row.nodeID)'s neighbour compact index \(neighbourIdx) is not present in the graphRows() map — dangling edge. Pre-fix 'continue' shifts compact numbering, leaving live-b's neighbour blob pointing past the 2-element array.")
                    continue
                }
                #expect(resolvedID != row.nodeID,
                    "HC-D-5 F1 REGRESSION: \(row.nodeID)'s neighbour resolves to itself — self-loop. Pre-fix: live-c at compact 1 with neighbour blob [1] resolves to 'live-c'. Post-fix tombstone at compact 0 corrects numbering so neighbour [1] resolves to 'live-b'.")
            }
        }
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
