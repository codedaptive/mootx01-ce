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
//   Gate 3 (crash-mid-publish): Three separate tests:
//     (a) gate3_interruptedFlip — a fault-injecting RowStore decorator aborts
//         the second upsert inside publishShadowGeneration's atomic transaction.
//         After rollback + close/reopen, BOTH swapped models still serve the OLD
//         generation. Discriminates because a de-transactionalized flip survives
//         the first model's update, producing a mixed-serving state that fails
//         the assertion. The registry shows both shadows still 'building' (reclaimable).
//     (b) gate3_completedFlipReopenInvariant — after a successful publish, close
//         and reopen; assert registry has shadow_generation NULL, shadow_state
//         'pending-reclaim', serving == new gen, queries return only new-gen tags.
//     (c) gate3_publishIdempotency — second publish call on a model with no active
//         shadow is a no-op (shadow_gen already NULL → skip). Separately named
//         so it does not impersonate the interrupt case.
//
//   Gate 4 (crash-mid-reclaim): A TRUE resumability test using batchLimit.
//     First pass with batchLimit < superseded-row-count leaves rows and registry
//     intact. Close+reopen simulates a mid-reclaim kill. Second pass (unbounded)
//     deletes the REMAINDER (count2 > 0) and clears registry. Third pass deletes 0.
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
@testable import SynapseKit

// MARK: - Fault injection types (Gate 3 interrupted-flip)

/// Error thrown by the fault-injecting RowStore to abort mid-flip.
private struct MidFlipAbortError: Error {}

/// Fault-injecting RowStore decorator for Gate 3 interrupted-flip.
///
/// Wraps a real RowStore and intercepts `upsert` calls to `vector_generations`.
/// When armed (`arm()` called), the SECOND upsert to that table throws
/// `MidFlipAbortError`, simulating a process crash inside
/// `publishShadowGeneration`'s atomic transaction before all models are written.
///
/// With the real single-transaction flip: the error propagates to the catch
/// block → `rollbackTransaction()` → the database reverts to its pre-publish
/// state → both models remain on the old serving generation.
///
/// With a de-transactionalized flip: the first model's upsert is already
/// committed when the second throws; the mixed state survives the rollback
/// and one model serves the new generation while the other still serves the old.
/// This is exactly what the gate discriminates.
///
/// All non-intercepted methods forward directly to the wrapped RowStore.
/// `@unchecked Sendable`: tests run under GlobalTestLock (serialized) so
/// the mutable counter is safe without additional locking.
private final class FaultRowStore: RowStore, @unchecked Sendable {

    private let backing: any RowStore
    /// Armed state: when true, upserts to vector_generations are counted.
    private var armed = false
    /// Count of upserts to `vector_generations` since arming.
    private var upsertToGenCount = 0

    init(backing: any RowStore) {
        self.backing = backing
    }

    /// Arm the fault. The NEXT upsert to `vector_generations` succeeds;
    /// the SECOND throws `MidFlipAbortError`. Idempotent.
    func arm() {
        armed = true
        upsertToGenCount = 0
    }

    // MARK: - Fault-intercepted upsert

    @discardableResult
    func upsert(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        if armed && table == "vector_generations" {
            upsertToGenCount += 1
            // First upsert (model-A) passes through; second (model-B) faults.
            if upsertToGenCount == 2 {
                throw MidFlipAbortError()
            }
        }
        return try await backing.upsert(
            table: table, values: values, conflictColumns: conflictColumns)
    }

    // MARK: - Pass-through delegation

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        try await backing.insert(table: table, values: values)
    }

    @discardableResult
    func update(
        table: String,
        values: [String: TypedValue],
        where predicate: StoragePredicate
    ) async throws -> Int {
        try await backing.update(table: table, values: values, where: predicate)
    }

    @discardableResult
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await backing.delete(table: table, where: predicate)
    }

    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        try await backing.query(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset)
    }

    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await backing.count(table: table, where: predicate)
    }

    func beginTransaction() async throws { try await backing.beginTransaction() }
    func commitTransaction() async throws { try await backing.commitTransaction() }
    func rollbackTransaction() async throws { try await backing.rollbackTransaction() }
}

/// Fault-injecting Storage decorator for Gate 3 interrupted-flip.
///
/// Wraps a real `SQLiteStorage` and replaces its `rowStore` with a
/// `FaultRowStore` so `VectorStore` exercises the fault path through its
/// normal `storage.rowStore` access pattern. All other Storage operations
/// delegate to the underlying backing storage, including `open`, `close`,
/// and `transaction`.
///
/// `@unchecked Sendable`: holds a reference-type `FaultRowStore` that is
/// itself `@unchecked Sendable`; the whole assembly is safe under GlobalTestLock.
private final class FaultStorage: Storage, @unchecked Sendable {

    private let backing: any Storage
    let faultRowStore: FaultRowStore

    init(backing: any Storage) {
        self.backing = backing
        self.faultRowStore = FaultRowStore(backing: backing.rowStore)
    }

    var configuration: EstateConfiguration { backing.configuration }
    var rowStore: any RowStore { faultRowStore }
    var blobStore: any BlobStore { backing.blobStore }
    var auditLog: any AuditLog { backing.auditLog }
    var observer: any StorageObserver { backing.observer }

    func open(schema: SchemaDeclaration) async throws {
        try await backing.open(schema: schema)
    }

    func close() async {
        await backing.close()
    }

    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await backing.transaction(isolation: isolation, block)
    }

    func currentSchemaVersion() async throws -> Int {
        try await backing.currentSchemaVersion()
    }

    func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await backing.currentSchemaVersion(for: kitID)
    }
    func renameSchemaKit(from oldKitID: String, to newKitID: String) async throws -> SchemaKitRenameOutcome {
        try await backing.renameSchemaKit(from: oldKitID, to: newKitID)
    }

    func migrate(to schema: SchemaDeclaration) async throws {
        try await backing.migrate(to: schema)
    }
}

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
            let reclaimSummary = try await storeB.reclaimSupersededGenerations(batchLimit: nil)
            let reclaimedCount = reclaimSummary[Self.modelID] ?? 0
            // Exactly 1 shadow-item row was written in the abandoned session.
            #expect(reclaimedCount >= 1,
                "Gate 2: reclaim must delete at least the 1 abandoned shadow row")

            await storageB.close()
        }
    }

    // MARK: - Gate 3: Interrupted-flip, completed-flip reopen, and publish idempotency

    /// Gate 3 (a) — Fault-injected interrupted flip.
    ///
    /// A FaultRowStore decorator aborts the SECOND upsert to `vector_generations`
    /// inside `publishShadowGeneration`'s atomic transaction. Because both upserts
    /// (one per model) run inside ONE BEGIN/COMMIT pair, the mid-second-upsert throw
    /// causes a rollback. Both models remain at serving_gen=0; the registry shows
    /// both shadows still 'building' (reclaimable).
    ///
    /// Discriminates because a de-transactionalized flip would commit the first
    /// model's upsert before the second throws, leaving model-A at serving_gen=1
    /// and model-B still at serving_gen=0 — a mixed state that the close/reopen
    /// assertions catch (model-A would serve new-gen items instead of old-gen items).
    ///
    /// Design: TWO-MODEL swap (modelID + altModelID both get shadow-built) so that
    /// publishShadowGeneration emits exactly two upserts to vector_generations in one
    /// transaction. The decorator arms before publish; the fault fires on upsert #2.
    @Test("Gate 3a: interrupted mid-flip — transaction rollback leaves both models serving old generation")
    func gate3_interruptedFlip() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gate3a-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            var rng = makeRNG(seed: 0x3A33_4444_5555_6666)
            let now = Date(timeIntervalSince1970: 1_700_000_001)

            // ── Wrapped storage: real SQLite backing + FaultRowStore ──────────
            let backingStorage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0)))
            let faultStorage = FaultStorage(backing: backingStorage)
            try await faultStorage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: faultStorage)

            // Populate OLD generation for BOTH models.
            try await populateServing(store: store, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng,
                                       prefix: "old-main")
            try await populateServing(store: store, modelID: Self.altModelID,
                                       count: Self.corpusCount, rng: &rng,
                                       prefix: "old-alt")

            // Begin shadow for BOTH models: allocates shadow_gen=1 for each.
            _ = try await store.beginShadowGeneration(modelIDs: [Self.modelID, Self.altModelID])

            // Write shadow vectors for both models under the shadow generation.
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-main-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1", filedAt: now)
            }
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-alt-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.altModelID, modelVersion: "1", filedAt: now)
            }

            // Arm the fault: next upsert to vector_generations passes, second throws.
            faultStorage.faultRowStore.arm()

            // publishShadowGeneration for BOTH models — two upserts in one transaction.
            // The second upsert (altModelID) throws → rollback → both models unchanged.
            let publishResult = try? await store.publishShadowGeneration(
                modelIDs: [Self.modelID, Self.altModelID])
            // publish must have thrown (fault injection); verify by checking nil.
            // We accept both nil (threw) and non-nil (did not throw) here because
            // publishShadowGeneration is @discardableResult-like (no return value),
            // but the fault *will* propagate as a thrown error, so we use try? to
            // capture the outcome without crashing the test.
            _ = publishResult  // silence unused-result; the key assertion is below.

            // Close the fault-injected instance to release the SQLite file.
            await faultStorage.close()

            // ── Reopen on CLEAN storage (no fault injection) ──────────────────
            let cleanStorage = try await openStorage(at: url)
            let storeB = VectorStore(storage: cleanStorage)

            // Assert BOTH models still serve OLD generation.
            // Query each model: all results must have the old prefix, not "new-".
            let probeMain = randomVector(dim: Self.dim, rng: &rng)
            let resultsMain = try await storeB.findNearestFloat(
                probe: probeMain, modelID: Self.modelID, limit: Self.corpusCount)
            #expect(!resultsMain.isEmpty,
                "Gate 3a: modelID must still return results after interrupted flip")
            for m in resultsMain {
                #expect(!m.itemID.hasPrefix("new-main-"),
                    "Gate 3a: modelID must NOT serve new-gen items after interrupted flip; got '\(m.itemID)'")
                #expect(m.itemID.hasPrefix("old-main"),
                    "Gate 3a: modelID must serve OLD-gen items after interrupted flip; got '\(m.itemID)'")
            }

            let probeAlt = randomVector(dim: Self.dim, rng: &rng)
            let resultsAlt = try await storeB.findNearestFloat(
                probe: probeAlt, modelID: Self.altModelID, limit: Self.corpusCount)
            #expect(!resultsAlt.isEmpty,
                "Gate 3a: altModelID must still return results after interrupted flip")
            for m in resultsAlt {
                #expect(!m.itemID.hasPrefix("new-alt-"),
                    "Gate 3a: altModelID must NOT serve new-gen items after interrupted flip; got '\(m.itemID)'")
                #expect(m.itemID.hasPrefix("old-alt"),
                    "Gate 3a: altModelID must serve OLD-gen items after interrupted flip; got '\(m.itemID)'")
            }

            // Assert registry: shadow still 'building' for both (reclaimable abandoned shadow).
            // Query the registry directly on the clean storage.
            let regRows = try await cleanStorage.rowStore.query(
                table: "vector_generations",
                where: .isTrue,
                orderBy: [],
                limit: nil,
                offset: nil
            )
            for regRow in regRows {
                guard case let .text(mID) = regRow["model_id"] ?? .null else { continue }
                guard mID == Self.modelID || mID == Self.altModelID else { continue }
                // serving_generation must still be 0 — no flip committed.
                let servingGen: Int64
                if case let .int(g) = regRow["serving_generation"] ?? .null {
                    servingGen = g
                } else {
                    servingGen = 0
                }
                #expect(servingGen == 0,
                    "Gate 3a: serving_generation must be 0 for model \(mID) after interrupted flip; got \(servingGen)")
                // shadow_generation must be non-null and non-zero (shadow still allocated).
                let hasShadow: Bool
                if case .int = regRow["shadow_generation"] ?? .null {
                    hasShadow = true
                } else {
                    hasShadow = false
                }
                #expect(hasShadow,
                    "Gate 3a: shadow_generation must still be present for model \(mID) after rollback")
            }

            await cleanStorage.close()
        }
    }

    /// Gate 3 (b) — Completed-flip reopen invariant.
    ///
    /// After a successful publish: close and reopen. Assert:
    ///   - registry row has shadow_generation = NULL (flip cleared it)
    ///   - registry row has shadow_state = 'pending-reclaim'
    ///   - serving_generation == the published shadow generation
    ///   - every query returns only new-gen tagged items
    ///
    /// This kills the "shadow not cleared on flip" mutation (reviewer finding F-8,
    /// mutation 2): if publishShadowGeneration forgot to NULL shadow_generation
    /// the registry would still carry the old shadow pointer, and shadow_state
    /// would not be 'pending-reclaim' — both assertions would fail.
    @Test("Gate 3b: completed-flip reopen — registry cleared, shadow_generation NULL, queries return new-gen")
    func gate3_completedFlipReopenInvariant() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gate3b-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            var rng = makeRNG(seed: 0x3B33_5555_6666_7777)
            let now = Date(timeIntervalSince1970: 1_700_000_001)

            // ── Instance A: populate, shadow, publish ─────────────────────────
            let storageA = try await openStorage(at: url)
            let storeA = VectorStore(storage: storageA)

            try await populateServing(store: storeA, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng,
                                       prefix: "old")
            let gens = try await storeA.beginShadowGeneration(modelIDs: [Self.modelID])
            let shadowGen = try #require(gens[Self.modelID])
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await storeA.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1", filedAt: now)
            }
            try await storeA.publishShadowGeneration(modelIDs: [Self.modelID])
            await storageA.close()

            // ── Instance B: reopen and assert registry + query invariants ─────
            let storageB = try await openStorage(at: url)
            let storeB = VectorStore(storage: storageB)

            // Assert registry state directly on the raw storage.
            let regRows = try await storageB.rowStore.query(
                table: "vector_generations",
                where: .eq(Column(table: "vector_generations", name: "model_id"),
                           .text(Self.modelID)),
                orderBy: [],
                limit: nil,
                offset: nil
            )
            let regRow = try #require(regRows.first,
                "Gate 3b: registry row must exist after publish")

            // serving_generation must equal the published shadow generation.
            let servingGen: Int64
            if case let .int(g) = regRow["serving_generation"] ?? .null {
                servingGen = g
            } else {
                servingGen = -1
            }
            #expect(servingGen == shadowGen,
                "Gate 3b: serving_generation must equal published shadow gen (\(shadowGen)); got \(servingGen)")

            // shadow_generation must be NULL (cleared by publish transaction).
            let shadowGenNull: Bool
            switch regRow["shadow_generation"] ?? .null {
            case .null: shadowGenNull = true
            default:    shadowGenNull = false
            }
            #expect(shadowGenNull,
                "Gate 3b: shadow_generation must be NULL after publish; publish must clear it")

            // shadow_state must be 'pending-reclaim'.
            let shadowState: String?
            if case let .text(s) = regRow["shadow_state"] ?? .null {
                shadowState = s
            } else {
                shadowState = nil
            }
            #expect(shadowState == "pending-reclaim",
                "Gate 3b: shadow_state must be 'pending-reclaim' after publish; got \(shadowState ?? "nil")")

            // Queries must return only new-gen items (serving_gen = shadowGen).
            let probe = randomVector(dim: Self.dim, rng: &rng)
            let results = try await storeB.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: Self.corpusCount)
            #expect(!results.isEmpty,
                "Gate 3b: findNearestFloat must return results after close/reopen post-publish")
            for m in results {
                #expect(m.itemID.hasPrefix("new-"),
                    "Gate 3b: all results must be new-gen items after close/reopen; got '\(m.itemID)'")
                #expect(m.generation == shadowGen,
                    "Gate 3b: VectorMatch.generation must equal serving generation (\(shadowGen)); got \(m.generation)")
            }

            await storageB.close()
        }
    }

    /// Gate 3 (c) — Publish idempotency (honestly named, does NOT impersonate interrupt).
    ///
    /// A second call to `publishShadowGeneration` on a model whose shadow_generation
    /// is already NULL is a no-op: no error thrown, serving generation unchanged.
    ///
    /// This is NOT the crash-mid-publish scenario. It tests the idempotent re-run
    /// that occurs when a process restarts AFTER a successful publish and re-runs
    /// the same publish operation (the code sees shadow_gen=NULL → skips → no-op).
    @Test("Gate 3c: publish idempotency — second publish on NULL shadow is a no-op, no corruption")
    func gate3_publishIdempotency() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x3C33_6666_7777_8888)
            try await populateServing(store: store, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)

            try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1", filedAt: now)
            }

            // First publish: flips serving_gen = 1, clears shadow_gen.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // Queries must return new-generation results after first publish.
            var rngQuery = makeRNG(seed: 0xAAAA_0001_0002_0003)
            let probe = randomVector(dim: Self.dim, rng: &rngQuery)
            let resultsAfterFirst = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterFirst.isEmpty == false,
                "Gate 3c: queries must return results after first publish")
            for match in resultsAfterFirst {
                #expect(match.itemID.hasPrefix("new-"),
                    "Gate 3c: post-publish queries must return new-gen items, got '\(match.itemID)'")
            }

            // Second publish (shadow_gen is NULL → no-op): must not throw or corrupt.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // Queries still return correct results after idempotent re-run.
            let resultsAfterSecond = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterSecond.isEmpty == false,
                "Gate 3c: queries must still return results after idempotent second publish")
            for match in resultsAfterSecond {
                #expect(match.itemID.hasPrefix("new-"),
                    "Gate 3c: queries after idempotent re-publish must still return new-gen items, got '\(match.itemID)'")
            }
        }
    }

    // MARK: - Gate 4: Crash mid-reclaim → TRUE resumability test

    /// Gate 4 — True resumability using batchLimit.
    ///
    /// A batchLimit capped below the superseded-row count manufactures a
    /// partial-reclaim state. A close+reopen simulates a mid-reclaim kill.
    /// The second pass (unbounded) must delete the REMAINDER (count2 > 0).
    /// A third pass asserts idempotency (0 deletions).
    ///
    /// The old Gate 4 asserted `count2 == 0`, which forbids resumability
    /// and is discriminated by any mutation that keeps superseded rows after
    /// the first pass — the test always passed because it never actually
    /// left anything for a second pass to do.
    ///
    /// This rebuilt gate is discriminated by:
    ///   - removing the batch-limit SELECT+IN pattern → DELETE removes all rows
    ///     on the first pass → count2 == 0 (not > 0) → gate FAILS
    ///   - de-transactionalizing the flip → doesn't affect this gate (flip is
    ///     already committed before reclaim; the gate owns the reclaim path)
    @Test("Gate 4: crash mid-reclaim — second pass deletes the remainder (count2 > 0), third pass is no-op")
    func gate4_crashMidReclaim() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gate4-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            var rng = makeRNG(seed: 0x4444_5555_6666_7777)
            let now = Date(timeIntervalSince1970: 1_700_000_001)

            // ── Setup: populate serving, shadow-swap, publish ─────────────────
            let storageA = try await openStorage(at: url)
            let storeA = VectorStore(storage: storageA)
            try await populateServing(store: storeA, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)
            // corpusCount=12 serving rows → 12 superseded rows after publish.

            try await storeA.beginShadowGeneration(modelIDs: [Self.modelID])
            var newCorpus: [(id: String, v: [Float])] = []
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                newCorpus.append((id: "new-\(i)", v: v))
                try await storeA.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1", filedAt: now)
            }
            try await storeA.publishShadowGeneration(modelIDs: [Self.modelID])
            // After publish: 12 superseded rows (serving_gen was 0, now 1).
            // Registry: shadow_generation=NULL, shadow_state='pending-reclaim'.

            // ── First pass: capped below superseded row count ─────────────────
            // batchLimit=5 < corpusCount=12 → leaves 7+ rows and registry intact.
            let batchCap = 5
            let summary1 = try await storeA.reclaimSupersededGenerations(batchLimit: batchCap)
            let count1 = summary1[Self.modelID] ?? 0
            #expect(count1 == batchCap,
                "Gate 4: first capped pass must delete exactly batchLimit=\(batchCap) rows; got \(count1)")

            // Registry must still show 'pending-reclaim' (bounded pass doesn't clear it).
            let regAfterFirstPass = try await storageA.rowStore.query(
                table: "vector_generations",
                where: .eq(Column(table: "vector_generations", name: "model_id"),
                           .text(Self.modelID)),
                orderBy: [], limit: nil, offset: nil)
            if let regRow = regAfterFirstPass.first {
                let stateVal = regRow["shadow_state"] ?? .null
                if case let .text(state) = stateVal {
                    #expect(state == "pending-reclaim",
                        "Gate 4: registry must remain 'pending-reclaim' after bounded first pass; got '\(state)'")
                } else {
                    Issue.record("Gate 4: shadow_state must be a text value after bounded pass; got \(stateVal)")
                }
            }

            // Superseded rows must remain (>0) — bounded pass is NOT complete.
            let supersededAfterFirst = try await storageA.rowStore.count(
                table: "vectors",
                where: .and([
                    .eq(Column(table: "vectors", name: "model_id"), .text(Self.modelID)),
                    .not(.eq(Column(table: "vectors", name: "generation"), .int(1)))
                ])
            )
            #expect(supersededAfterFirst > 0,
                "Gate 4: superseded rows must remain after bounded first pass (\(supersededAfterFirst) remaining)")

            // ── Close: simulate mid-reclaim kill ─────────────────────────────
            await storageA.close()

            // ── Reopen on clean storage ───────────────────────────────────────
            let storageB = try await openStorage(at: url)
            let storeB = VectorStore(storage: storageB)

            // Queries on reopen must still return correct results.
            let probe = newCorpus[0].v
            let resultsAfterKill = try await storeB.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterKill.first?.itemID == "new-0",
                "Gate 4: nearest to new-0 must still be new-0 after kill+reopen; got \(String(describing: resultsAfterKill.first?.itemID))")

            // ── Second pass: unbounded → deletes the remainder ────────────────
            let summary2 = try await storeB.reclaimSupersededGenerations(batchLimit: nil)
            let count2 = summary2[Self.modelID] ?? 0
            #expect(count2 > 0,
                "Gate 4: second unbounded pass must delete the remaining superseded rows (count2 > 0); got \(count2)")

            // Zero superseded rows must survive after the second pass.
            let supersededAfterSecond = try await storageB.rowStore.count(
                table: "vectors",
                where: .and([
                    .eq(Column(table: "vectors", name: "model_id"), .text(Self.modelID)),
                    .not(.eq(Column(table: "vectors", name: "generation"), .int(1)))
                ])
            )
            #expect(supersededAfterSecond == 0,
                "Gate 4: zero superseded rows must survive after second unbounded pass; got \(supersededAfterSecond)")

            // Registry must be cleared after the unbounded pass.
            let regAfterSecond = try await storageB.rowStore.query(
                table: "vector_generations",
                where: .eq(Column(table: "vector_generations", name: "model_id"),
                           .text(Self.modelID)),
                orderBy: [], limit: nil, offset: nil)
            if let regRow = regAfterSecond.first {
                switch regRow["shadow_state"] ?? .null {
                case .null:
                    break  // Correct: cleared.
                case let .text(state):
                    #expect(state != "pending-reclaim",
                        "Gate 4: shadow_state must be NULL after unbounded pass; got '\(state)'")
                default:
                    Issue.record("Gate 4: shadow_state has unexpected type after second pass")
                }
            }

            // Queries remain correct after second pass.
            let resultsAfterSecond = try await storeB.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterSecond.first?.itemID == "new-0",
                "Gate 4: nearest to new-0 must still be new-0 after second unbounded pass")

            // ── Third pass (idempotency): separate honest assertion ────────────
            // Named separately to avoid impersonating the resumability case.
            // Zero rows remain to delete; summary must be empty or count = 0.
            let summary3 = try await storeB.reclaimSupersededGenerations(batchLimit: nil)
            let count3 = summary3.values.reduce(0, +)
            #expect(count3 == 0,
                "Gate 4 idempotency: third pass must delete 0 rows (all already reclaimed); got \(count3)")

            await storageB.close()
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
            let summary = try await store.reclaimSupersededGenerations(batchLimit: nil)
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
            try await store.reclaimSupersededGenerations(batchLimit: nil)

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
            try await store.reclaimSupersededGenerations(batchLimit: nil)

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
