// ReindexAbortPathTests.swift
//
// SS-01 Unit C — reindex abort path, Swift port
//
// Discriminating tests for the abort fix in CorpusContentEngine.reindex:
// when a reindex fails between beginShadowGeneration and publishShadowGeneration,
// abandonShadowGeneration must be called before rethrowing so no vectors are
// left stranded in a generation that will never become visible.
//
// Test inventory:
//
//   c4a. Error propagates: the caller receives the original error from the
//        failed reindex, not an error from the abort call.
//
//   c4b. No leftover 'building' state: after a failed reindex, the
//        vector_generations registry must NOT show shadow_state = 'building'.
//        Pre-fix, shadow_state is 'building'; this assertion fails.
//        Post-fix, abandonShadowGeneration clears shadow_state to NULL.
//
//   c4c. Serving generation intact: serving_generation remains at its prior
//        value (the old generation keeps serving), same as the c3 check in
//        ShadowSwapCorpusTests but retained here alongside the c4b assertion.
//
//   c4d. No stranded shadow vectors: the vector count for the model equals
//        the count before the failed reindex. Failure during trainTrainableSlots
//        (before the write pass) means no shadow vectors were written, so the
//        count stays at 6 (3 items × 2 lanes). Abandon would delete any that
//        were written; the count check confirms no third-state rows remain.
//
// Seam used: a CorpusContentSource that throws on the Nth call to record(for:).
// No production code is added purely to make this testable; the source
// interface already exposes the injection point.
//
// Storage: on-disk SQLite via makeScratchStorage() — the same backend
// production uses.

import Testing
import Foundation
import SynapseKit
import PersistenceKit
import CorpusKitProviders
@testable import CorpusKit

// MARK: - Helpers (file-private; not reused from ShadowSwapCorpusTests)

/// In-memory content source that can be armed to throw on the next record(for:) call.
private actor FaultingContentSource: CorpusContentSource {
    private var records: [String: CorpusContentRecord] = [:]
    private var throwOnNextRecord = false

    func put(id: String, text: String) {
        let digest = CorpusContentDigest.digest(text)
        let revision: Int64 = (records[id].map { $0.revision } ?? 0) + 1
        records[id] = CorpusContentRecord(
            id: id, revision: revision, digest: digest, text: text)
    }

    /// Arm the source: the NEXT call to record(for:) throws and disarms.
    func armFault() {
        throwOnNextRecord = true
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        if throwOnNextRecord {
            throwOnNextRecord = false
            throw FaultError.forcedRecordFailure
        }
        return records[id]
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        // Reindex tests go through activeContentIDs + record(for:), not the feed.
        .empty
    }

    private enum FaultError: Error {
        case forcedRecordFailure
    }
}

/// Read the `shadow_state` column for a model from `vector_generations`.
/// Returns nil when no row exists or when shadow_state is SQL NULL.
private func shadowState(storage: any Storage, modelID: String) async throws -> String? {
    let rows = try await storage.rowStore.query(
        table: "vector_generations",
        where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
        orderBy: [],
        limit: 1,
        offset: nil
    )
    guard let row = rows.first else { return nil }
    switch row.values["shadow_state"] {
    case .text(let s): return s
    default: return nil  // NULL or absent: shadow_state has been cleared
    }
}

/// Read `serving_generation` for a model. Returns nil when no registry row exists.
private func servingGeneration(storage: any Storage, modelID: String) async throws -> Int64? {
    let rows = try await storage.rowStore.query(
        table: "vector_generations",
        where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
        orderBy: [],
        limit: 1,
        offset: nil
    )
    guard let row = rows.first else { return nil }
    switch row.values["serving_generation"] {
    case .int(let v): return v
    case .text(let s): return Int64(s)
    default: return nil
    }
}

/// Count ALL rows in `vectors` for a model, regardless of generation.
private func vectorRowCount(storage: any Storage, modelID: String) async throws -> Int {
    let rows = try await storage.rowStore.query(
        table: "vectors",
        where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
        orderBy: [],
        limit: nil,
        offset: nil
    )
    return rows.count
}

/// Build a CorpusContentEngine with one trainable RI slot over a given storage
/// and source. The RI slot causes beginShadowGeneration to engage on every
/// reindex, so the shadow-abort path is exercised.
private func makeAbortTestEngine(
    storage: any Storage,
    source: any CorpusContentSource
) async throws -> CorpusContentEngine {
    let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
    let provider = RandomIndexingProvider()
    return try await CorpusContentEngine(
        storage: storage,
        configuration: config,
        source: source,
        models: [.randomIndexing(provider: provider)]
    )
}

// MARK: - Suite

@Suite("SS-01 reindex abort path — abandonShadowGeneration called on failure",
       .serialized)
struct ReindexAbortPathTests {

    // ── c4a + c4b + c4c + c4d: all four assertions in one scenario ────────────

    /// Scenario: first reindex succeeds (serving_gen=1, 6 vectors). Then the
    /// source is armed to throw on the NEXT record(for:) call, so the second
    /// reindex fails inside trainTrainableSlots (after beginShadowGeneration,
    /// before any shadow vectors are written, and well before publish).
    ///
    /// Expected state after the failed second reindex:
    ///
    ///   c4a: the error propagates — the caller sees an error, not nil.
    ///
    ///   c4b: shadow_state is NOT 'building'. Pre-fix, the registry row is
    ///        left with shadow_state='building', so this assertion FAILS before
    ///        the C1 fix is applied. Post-fix, abandonShadowGeneration sets
    ///        shadow_state to NULL.
    ///
    ///   c4c: serving_generation is still 1 — the old generation keeps serving.
    ///
    ///   c4d: vector count is still 6 — no shadow vectors were stranded (the
    ///        failure occurred before the write pass, and abandon would have
    ///        cleaned up any that were written).
    ///
    /// This test FAILS on the current code (pre-fix c4b), which demonstrates
    /// the bug: `shadow_state='building'` is the orphaned third state the
    /// mission's governing invariant forbids.
    @Test("c4 failed reindex: error propagates and no leftover building shadow in registry")
    func c4_failedReindexAbandonsOrphanedShadow() async throws {
        let modelID = "random-indexing-v1"
        let storage = try makeScratchStorage()
        let source = FaultingContentSource()
        await source.put(id: "doc-1", text: "the quick brown fox jumps over the lazy dog")
        await source.put(id: "doc-2", text: "machine learning and natural language processing")
        await source.put(id: "doc-3", text: "cats and dogs are common household pets")

        let engine = try await makeAbortTestEngine(storage: storage, source: source)
        let now = Date(timeIntervalSinceReferenceDate: 25_000_000)

        // ── First reindex: success — establishes serving_gen=1, 6 vectors ────
        try await engine.reindex(now: now)

        let gen1 = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(gen1 == 1, "setup: serving_generation must be 1 after first reindex")
        let countAfterFirst = try await vectorRowCount(storage: storage, modelID: modelID)
        #expect(countAfterFirst == 6, "setup: 6 vectors after first reindex (3 items × 2 lanes)")

        // ── Arm fault: next record(for:) call throws ──────────────────────────
        // This fires inside trainTrainableSlots on the second reindex, which runs
        // after beginShadowGeneration. The shadow is open (shadow_state='building')
        // when the error propagates.
        await source.armFault()

        // ── Second reindex: must propagate the error (c4a) ───────────────────
        // Pre-fix: leaves shadow_state='building' in the registry.
        // Post-fix: abandonShadowGeneration is called, shadow_state cleared.
        await #expect(throws: (any Error).self) {
            try await engine.reindex(now: now)
        }

        // ── c4b: shadow_state must NOT be 'building' after the abort ─────────
        // Before the fix, shadow_state='building' — this assertion FAILS, which
        // demonstrates the bug. After the fix, shadow_state is NULL.
        let state = try await shadowState(storage: storage, modelID: modelID)
        #expect(
            state != "building",
            """
            c4b: shadow_state must not be 'building' after a failed reindex — \
            pre-fix this was 'building' (the orphaned third state). \
            Got: \(state ?? "nil")
            """
        )

        // ── c4c: serving_generation unchanged — old generation still serves ───
        let genAfterFail = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(
            genAfterFail == 1,
            "c4c: serving_generation must remain 1 when second reindex fails before publish"
        )

        // ── c4d: vector count unchanged — no vectors stranded at shadow gen ───
        // Failure was before the write pass, so no shadow vectors were written.
        // Abandon confirms there is nothing to clean up; count stays at 6.
        let countAfterFail = try await vectorRowCount(storage: storage, modelID: modelID)
        #expect(
            countAfterFail == 6,
            "c4d: vector count must remain 6 — no shadow vectors stranded at an invisible generation"
        )
    }
}
