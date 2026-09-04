// ShadowGenerationLifecycleTests.swift
//
// Regression tests for SS-01 — shadow-generation vector lifecycle.
//
// Each test asserts the governing invariant:
//   Every vectors row is at its model's serving_generation, or at its model's
//   CURRENTLY ACTIVE shadow generation. No third state exists.
//
// Eight gates (labelled to match the deliverable numbering in the unit brief):
//
//   A1a — abandon deletes the shadow generation's rows and leaves every
//          serving-generation row intact and queryable.
//   A1b — abandon is idempotent (second call deletes nothing).
//   A1c — after begin → write → abandon, no row exists at a generation that is
//          neither serving nor an active shadow.
//   A2  — begin over a pre-existing abandoned 'building' shadow leaves no rows
//          from the stale generation on disk.
//   A3a — reclaim removes an abandoned 'building' shadow (not opened by this
//          process instance).
//   A3b — reclaim does NOT remove a shadow that is genuinely open in this
//          process instance (present in openShadows).
//   A4a — reconcileModelVectors rows are visible to a read after a successful
//          swap (fails pre-fix: rows landed at generation 0 while serving is 1).
//   A4b — reconcileModelVectors during an open shadow build does not delete
//          serving-generation rows.

import Testing
import Foundation
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
@testable import SynapseKit

// MARK: - Shared helpers

/// Open a fresh SQLite storage with the VectorStore schema applied.
private func openVectorStorage() async throws -> any Storage {
    let storage = try makeScratchStorage()
    try await storage.open(schema: VectorStore.schemaDeclaration)
    return storage
}

/// Count rows in the vectors table for a specific (modelID, generation) pair.
/// Bypasses all VectorStore serving-generation filters so the result reflects
/// what is physically on disk, not what would be served to queries.
private func rawVectorRowCount(
    storage: any Storage,
    modelID: String,
    generation: Int64
) async throws -> Int {
    let rows = try await storage.rowStore.query(
        table: "vectors",
        where: .and([
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            .eq(Column(table: "vectors", name: "generation"), .int(generation))
        ]),
        orderBy: [], limit: nil, offset: nil
    )
    return rows.count
}

/// Query all distinct generation values present in the vectors table for a
/// given modelID. Used to assert the governing invariant without relying on
/// any serving-generation filter.
private func distinctGenerations(
    storage: any Storage,
    modelID: String
) async throws -> Set<Int64> {
    let rows = try await storage.rowStore.query(
        table: "vectors",
        where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
        orderBy: [], limit: nil, offset: nil
    )
    var gens = Set<Int64>()
    for row in rows {
        if case let .int(g) = row["generation"] ?? .null { gens.insert(g) }
    }
    return gens
}

/// Count all rows for a given modelID across every generation in the vectors
/// table. Used by the generation-bound test to verify total row count does not
/// accumulate across successive reindex cycles.
private func totalVectorRowCount(
    storage: any Storage,
    modelID: String
) async throws -> Int {
    let rows = try await storage.rowStore.query(
        table: "vectors",
        where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
        orderBy: [], limit: nil, offset: nil
    )
    return rows.count
}

/// Check whether a specific (modelID, itemID, generation) combination exists.
/// Used to assert item-level existence without relying on aggregate counts.
private func vectorExistsForItem(
    storage: any Storage,
    modelID: String,
    itemID: String,
    generation: Int64
) async throws -> Bool {
    let rows = try await storage.rowStore.query(
        table: "vectors",
        where: .and([
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            .eq(Column(table: "vectors", name: "item_id"), .text(itemID)),
            .eq(Column(table: "vectors", name: "generation"), .int(generation))
        ]),
        orderBy: [], limit: 1, offset: nil
    )
    return !rows.isEmpty
}

/// Binary vector payload using the canonical 256-bit Engram wire format
/// (4 × UInt64 little-endian = 32 bytes). Required by BruteForceIndex.
private func binaryPayload(seed: UInt64 = 0) -> VectorPayload {
    VectorPayload(engram: Engram(blocks: seed, 0, 0, 0))
}

/// Write one binary vector row at whichever generation is currently active
/// (serving if no shadow; shadow if one is open).
private func writeBinaryVector(
    to store: VectorStore,
    itemID: String,
    modelID: String,
    seed: UInt64 = 0
) async throws {
    try await store.addPayload(
        itemID: itemID,
        vectorIndex: 0,
        payload: binaryPayload(seed: seed),
        modelID: modelID,
        modelVersion: "v1",
        filedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

// MARK: - Suite

@Suite("ShadowGenerationLifecycle", .serialized)
struct ShadowGenerationLifecycleTests {

    // MARK: A1a — abandon deletes shadow rows, serving rows survive

    /// Asserts: abandonShadowGeneration deletes exactly the shadow generation's
    /// rows and leaves every serving-generation row intact and queryable.
    ///
    /// Pre-fix failure evidence (A1a, compile):
    ///   ShadowGenerationLifecycleTests.swift:131:43: error: value of type
    ///   'VectorStore' has no member 'abandonShadowGeneration'
    ///   — the ABORT transition did not exist before deliverable A1.
    @Test("A1a: abandon deletes shadow rows and preserves serving rows")
    func abandonDeletesShadowPreservesServing() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a1a"

            // Write a serving-generation row (generation 0 before any swap).
            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID, seed: 0xAA)
            let servingGen: Int64 = 0

            // Open a shadow and write one row into it.
            let shadows = try await store.beginShadowGeneration(modelIDs: [modelID])
            let shadowGen = try #require(shadows[modelID])
            try await writeBinaryVector(to: store, itemID: "shadow-item", modelID: modelID, seed: 0xBB)

            // Pre-condition: shadow row exists.
            let shadowCountBefore = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: shadowGen)
            #expect(shadowCountBefore == 1, "Pre-condition: shadow row must exist before abandon")

            // Abandon the shadow.
            let deleted = try await store.abandonShadowGeneration(modelIDs: [modelID])

            // Shadow rows must be gone.
            let shadowCountAfter = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: shadowGen)
            #expect(shadowCountAfter == 0,
                    "abandon must delete shadow rows; found \(shadowCountAfter) at gen \(shadowGen)")

            // Serving row must still exist.
            let servingCount = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: servingGen)
            #expect(servingCount == 1,
                    "abandon must not delete serving rows; found \(servingCount) at gen \(servingGen)")

            // Return map must report the count deleted.
            #expect((deleted[modelID] ?? 0) == 1, "abandon must return count of deleted rows")
        }
    }

    // MARK: A1b — abandon is idempotent

    /// Asserts: calling abandonShadowGeneration twice does not error and the
    /// second call reports zero deleted rows.
    ///
    /// Pre-fix failure evidence (A1b, compile):
    ///   value of type 'VectorStore' has no member 'abandonShadowGeneration'
    @Test("A1b: abandon is idempotent")
    func abandonIsIdempotent() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a1b"

            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID)
            _ = try await store.beginShadowGeneration(modelIDs: [modelID])
            try await writeBinaryVector(to: store, itemID: "shadow-item", modelID: modelID, seed: 0xCC)

            // First abandon: deletes 1 row.
            let first = try await store.abandonShadowGeneration(modelIDs: [modelID])
            #expect((first[modelID] ?? 0) == 1, "First abandon must delete 1 row")

            // Second abandon: no 'building' shadow; must succeed with nothing deleted.
            let second = try await store.abandonShadowGeneration(modelIDs: [modelID])
            #expect((second[modelID] ?? 0) == 0,
                    "Second abandon must delete nothing; got \(second[modelID] ?? 0)")
        }
    }

    // MARK: A1c — invariant: no orphan generation after begin → write → abandon

    /// Asserts: after begin → write → abandon, the only generation present in
    /// the vectors table for this model is the serving generation. The abandoned
    /// shadow generation must not appear.
    ///
    /// Pre-fix failure evidence (A1c, compile):
    ///   value of type 'VectorStore' has no member 'abandonShadowGeneration'
    ///   — stale 'building' rows would persist on disk, violating the invariant.
    @Test("A1c: after begin→write→abandon, no orphan generation exists")
    func invariantNoOrphanGenerationAfterAbandon() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a1c"

            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID)
            let servingGen: Int64 = 0

            let shadows = try await store.beginShadowGeneration(modelIDs: [modelID])
            let shadowGen = try #require(shadows[modelID])
            try await writeBinaryVector(to: store, itemID: "shadow-item", modelID: modelID, seed: 0xDD)

            try await store.abandonShadowGeneration(modelIDs: [modelID])

            // Query all distinct generations on disk for this model.
            let generations = try await distinctGenerations(storage: storage, modelID: modelID)

            // The abandoned shadow generation must NOT appear.
            #expect(!generations.contains(shadowGen),
                    "Abandoned shadow generation \(shadowGen) must not exist on disk after abandon")
            #expect(generations == [servingGen],
                    "Only serving generation \(servingGen) should remain; found \(generations)")
        }
    }

    // MARK: A2 — begin over abandoned shadow deletes stale rows

    /// Asserts: beginShadowGeneration, called on a model that already has a
    /// 'building' shadow, deletes that shadow's rows before allocating the new
    /// generation. No row from the stale generation remains after the second
    /// begin.
    ///
    /// Pre-fix failure evidence (A2, runtime):
    ///   Expectation failed: staleCountAfter == 0
    ///   beginShadowGeneration must delete stale 'building' rows; 1 remain at gen 1
    ///   — before A2, beginShadowGeneration only numbered past the stale shadow.
    @Test("A2: begin over abandoned shadow removes stale rows")
    func beginOverAbandonedShadowDeletesStaleRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a2"

            // Write a serving row.
            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID)

            // First begin + write (simulates a crashed reindex).
            let firstShadows = try await store.beginShadowGeneration(modelIDs: [modelID])
            let staleGen = try #require(firstShadows[modelID])
            try await writeBinaryVector(to: store, itemID: "stale-item", modelID: modelID, seed: 0xEE)

            // Pre-condition: stale row exists.
            let staleCountBefore = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: staleGen)
            #expect(staleCountBefore == 1,
                    "Pre-condition: stale shadow row must exist before recovery begin")

            // Second begin — the crash-recovery path. Must delete stale rows.
            _ = try await store.beginShadowGeneration(modelIDs: [modelID])

            let staleCountAfter = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: staleGen)
            #expect(staleCountAfter == 0,
                    "beginShadowGeneration must delete stale 'building' rows; \(staleCountAfter) remain at gen \(staleGen)")
        }
    }

    // MARK: A3a — reclaim removes abandoned 'building' shadow from prior process

    /// Asserts: reclaimSupersededGenerations deletes rows from a 'building'
    /// shadow that was opened by a different VectorStore instance (simulated
    /// by using store A to seed the shadow then calling reclaim on a fresh
    /// store B whose openShadows is empty).
    ///
    /// Pre-fix failure evidence (A3a, runtime):
    ///   Expectation failed: countAfter == 0
    ///   reclaimSupersededGenerations must remove abandoned 'building' shadow rows; 1 remain
    ///   — before A3, reclaim protected every 'building' shadow unconditionally.
    @Test("A3a: reclaim removes abandoned building shadow from prior process")
    func reclaimRemovesAbandonedBuildingShadow() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let modelID = "lifecycle-a3a"

            // Use store A to set up an abandoned 'building' shadow.
            let storeA = VectorStore(storage: storage)
            try await writeBinaryVector(to: storeA, itemID: "serving-item", modelID: modelID)
            let shadows = try await storeA.beginShadowGeneration(modelIDs: [modelID])
            let staleGen = try #require(shadows[modelID])
            try await writeBinaryVector(to: storeA, itemID: "stale-item", modelID: modelID, seed: 0xFF)
            // storeA "crashes" — shadow stays 'building' in the DB; storeA is abandoned.

            // Open a FRESH store (simulates process restart). openShadows is empty.
            let storeB = VectorStore(storage: storage)

            // Pre-condition: stale row exists.
            let countBefore = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: staleGen)
            #expect(countBefore == 1, "Pre-condition: stale shadow row must exist before reclaim")

            // Reclaim from the fresh store. Must reclaim the abandoned shadow.
            _ = try await storeB.reclaimSupersededGenerations()

            let countAfter = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: staleGen)
            #expect(countAfter == 0,
                    "reclaimSupersededGenerations must remove abandoned 'building' shadow rows; \(countAfter) remain")
        }
    }

    // MARK: A3b — reclaim does NOT remove a genuinely open shadow

    /// Asserts: reclaimSupersededGenerations does not touch a 'building' shadow
    /// that was opened by this VectorStore instance (present in openShadows).
    ///
    /// This is a regression guard — the A3 change must not break the protection
    /// of genuinely in-flight shadows.
    ///
    /// Pre-fix behaviour: all 'building' shadows were protected, so this test
    /// passed before A3. Post-fix: only shadows in openShadows are protected,
    /// and the test still passes because openShadows contains this model.
    @Test("A3b: reclaim preserves a genuinely open shadow")
    func reclaimPreservesOpenShadow() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a3b"

            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID)
            let shadows = try await store.beginShadowGeneration(modelIDs: [modelID])
            let shadowGen = try #require(shadows[modelID])
            try await writeBinaryVector(to: store, itemID: "shadow-item", modelID: modelID, seed: 0x11)

            // Reclaim while the shadow is still open in this store.
            _ = try await store.reclaimSupersededGenerations()

            // Shadow row must still exist — it is genuinely in flight.
            let shadowCount = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: shadowGen)
            #expect(shadowCount == 1,
                    "reclaimSupersededGenerations must NOT remove an open shadow; found \(shadowCount) rows at gen \(shadowGen)")
        }
    }

    // MARK: A4a — reconcileModelVectors rows visible after swap

    /// Asserts: rows written by reconcileModelVectors are visible to a
    /// serving-generation read after a successful publishShadowGeneration.
    ///
    /// Pre-fix failure evidence (A4a, runtime — finding 98bb0fb):
    ///   Expectation failed: servingCount == 1
    ///   reconcileModelVectors row must be at serving generation 1; found 0
    ///   Expectation failed: gen0Count == 0
    ///   No reconciled row should be at generation 0 after swap; found 1
    ///   — reconcileModelVectors omitted "generation" from upsert values while
    ///     conflictColumns included "generation", so SQLite resolved against
    ///     the column default (0). After swap (serving_generation = 1), those
    ///     rows were invisible to the serving predicate.
    @Test("A4a: reconcileModelVectors rows are visible after swap")
    func reconcileRowsVisibleAfterSwap() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a4a"

            // Open a shadow and use reconcileModelVectors to write into it.
            _ = try await store.beginShadowGeneration(modelIDs: [modelID])

            let input = VectorPayloadInput(
                itemID: "reconcile-item",
                vectorIndex: 0,
                payload: binaryPayload(seed: 0x22),
                modelID: modelID,
                modelVersion: "v1",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            _ = try await store.reconcileModelVectors(modelID: modelID, expected: [input])

            // Publish the shadow.
            try await store.publishShadowGeneration(modelIDs: [modelID])
            // serving_generation is now 1 (the shadow gen).

            // The reconciled row must exist at generation 1, not at 0 (the pre-fix default).
            let servingCount = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: 1)
            #expect(servingCount == 1,
                    "reconcileModelVectors row must be at serving generation 1; found \(servingCount)")

            let gen0Count = try await rawVectorRowCount(storage: storage, modelID: modelID, generation: 0)
            #expect(gen0Count == 0,
                    "No reconciled row should be at generation 0 after swap; found \(gen0Count)")
        }
    }

    // MARK: A4b — reconcileModelVectors during shadow build preserves serving rows

    /// Asserts: when reconcileModelVectors is called during an open shadow
    /// build, it does not delete serving-generation rows.
    ///
    /// Pre-fix failure evidence (A4b, runtime):
    ///   Expectation failed: servingItemExists == true
    ///   reconcileModelVectors must not delete serving-item at serving gen 0
    ///   — the existingRows query had no generation filter, so staleKeys was
    ///     computed across ALL generations. The serving-generation row for
    ///     "serving-item" was absent from `expected` and was classified as stale,
    ///     then deleted. The item-specific check detects this.
    @Test("A4b: reconcileModelVectors during shadow build preserves serving rows")
    func reconcileDuringShadowPreservesServing() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "lifecycle-a4b"

            // Write a serving-generation row at generation 0.
            try await writeBinaryVector(to: store, itemID: "serving-item", modelID: modelID, seed: 0x33)
            let servingGen: Int64 = 0

            // Pre-condition: "serving-item" exists at gen 0.
            let existsBefore = try await vectorExistsForItem(storage: storage, modelID: modelID,
                                                              itemID: "serving-item", generation: servingGen)
            #expect(existsBefore, "Pre-condition: serving-item must exist at gen \(servingGen)")

            // Open a shadow.
            _ = try await store.beginShadowGeneration(modelIDs: [modelID])

            // Call reconcileModelVectors with an expected set that does NOT include
            // "serving-item". Pre-fix: existingRows had no generation filter, so
            // staleKeys included "serving-item" (at gen 0), which was then deleted.
            let newInput = VectorPayloadInput(
                itemID: "shadow-only-item",
                vectorIndex: 0,
                payload: binaryPayload(seed: 0x44),
                modelID: modelID,
                modelVersion: "v1",
                filedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            _ = try await store.reconcileModelVectors(modelID: modelID, expected: [newInput])

            // "serving-item" at gen 0 must still exist — the reconcile was scoped
            // to the shadow generation and must not have touched the serving gen.
            let existsAfter = try await vectorExistsForItem(storage: storage, modelID: modelID,
                                                             itemID: "serving-item", generation: servingGen)
            #expect(existsAfter,
                    "reconcileModelVectors must not delete serving-item at serving gen \(servingGen)")
        }
    }

    // MARK: BOUND — generation count stays bounded across successive reindex cycles

    /// Drives 12 successive full shadow-swap cycles (begin → write → publish → reclaim)
    /// against one model and asserts the governing invariant:
    ///
    ///   After a completed cycle-plus-reclaim, exactly ONE distinct generation
    ///   exists in the vectors table and the total row count equals VECTORS_PER_CYCLE.
    ///   Neither metric grows with the cycle number.
    ///
    /// Pre-fix failure: reclaimSupersededGenerations did not delete superseded
    /// (old serving) generation rows. After N cycles without working reclaim:
    ///   - N+1 distinct generations remained on disk (gens 0 through N)
    ///   - Total row count grew to (N+1) × VECTORS_PER_CYCLE
    /// The assertion `distinctGens.count == 1` would fail at cycle 1, where it
    /// found 2 distinct generations instead of 1.
    ///
    /// Printed series (iteration, distinct generation count, total row count) is
    /// captured in the test log so the exact measurements appear in the
    /// completion report without requiring a manual log parse.
    @Test("BOUND: generation count stays bounded across N successive reindex cycles")
    func generationCountStaysBoundedAcrossReindexCycles() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await openVectorStorage()
            let store = VectorStore(storage: storage)
            let modelID = "bound-measurement"
            let cycleCount = 12
            let vectorsPerCycle = 5

            // Seed the initial serving generation (generation 0).
            // Subsequent cycles will replace these rows via shadow swap.
            for i in 0..<vectorsPerCycle {
                try await writeBinaryVector(
                    to: store, itemID: "item-\(i)", modelID: modelID,
                    seed: UInt64(i + 1))
            }

            print("BOUND TEST — \(cycleCount) cycles, \(vectorsPerCycle) vectors/cycle")
            print("Iteration | Distinct Generations | Total Rows")

            for cycle in 1...cycleCount {
                // Open a new shadow generation.
                _ = try await store.beginShadowGeneration(modelIDs: [modelID])

                // Write the same item set into the shadow. Using the same item IDs
                // as the previous serving generation simulates a normal full reindex
                // where all items are re-embedded into the new model generation.
                for i in 0..<vectorsPerCycle {
                    try await writeBinaryVector(
                        to: store, itemID: "item-\(i)", modelID: modelID,
                        seed: UInt64(cycle * 1000 + i))
                }

                // Promote the shadow to serving.
                try await store.publishShadowGeneration(modelIDs: [modelID])

                // Reclaim the old serving generation's rows.
                _ = try await store.reclaimSupersededGenerations()

                // Measure what is physically on disk after reclaim.
                let distinctGens = try await distinctGenerations(storage: storage, modelID: modelID)
                let totalRows    = try await totalVectorRowCount(storage: storage, modelID: modelID)

                print("\(cycle) | \(distinctGens.count) | \(totalRows)")

                // The bound: exactly one generation and exactly vectorsPerCycle rows
                // survive a completed swap + reclaim. Pre-fix: both metrics grew
                // linearly with the cycle number.
                #expect(
                    distinctGens.count == 1,
                    "Cycle \(cycle): expected 1 distinct generation after reclaim; got \(distinctGens.count) — \(distinctGens)"
                )
                #expect(
                    totalRows == vectorsPerCycle,
                    "Cycle \(cycle): expected \(vectorsPerCycle) total rows after reclaim; got \(totalRows)"
                )
            }
        }
    }
}
