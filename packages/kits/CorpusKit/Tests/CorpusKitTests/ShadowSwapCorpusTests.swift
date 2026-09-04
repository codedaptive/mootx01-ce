// ShadowSwapCorpusTests.swift
//
// Tests for the shadow-swap reindex path wired into CorpusContentEngine
// (VEC-SHADOWSWAP-01 UNIT C, Part 1 + Part 4):
//
//   c1. Two consecutive reindex passes on a corpus with a trainable RI slot:
//       (a) first reindex trains, writes gen-1 vectors, publishes serving_gen=1;
//       (b) second reindex writes gen-2 vectors, publishes serving_gen=2, and
//           leaves the 3 gen-1 rows on-disk as pending-reclaim (total = 6 rows).
//
//       Why two passes: indexContent skips RI vectors while the slot is still
//       "untrained" in the engine's internal state (it has no persisted basis
//       blob yet). The first reindex trains the basis and writes gen-1 vectors;
//       the second reindex performs the full superseded-generation cycle.
//
//   c2. Recall-unchanged at engine level: the same BM25 query before and after
//       reindex returns the same item set. The swap replaces vectors without
//       losing indexed content.
//
//   c3. Reindex failure path: when the content source throws mid-iteration on
//       the second reindex attempt (after beginShadowGeneration but before
//       publishShadowGeneration), the error propagates and the previously
//       published generation continues serving (serving_generation stays at
//       the prior value).
//
// Storage: on-disk SQLite via makeScratchStorage() — the same backend
// production uses. InMemoryStorage hides SQLite-round-trip decode bugs and
// is not used here (see TestScratchStorage.swift comment).

import Testing
import Foundation
import SynapseKit
import PersistenceKit
import CorpusKitProviders
@testable import CorpusKit

// MARK: - Helpers

/// Simple in-memory CorpusContentSource backed by a dictionary.
private actor SimpleContentSource: CorpusContentSource {
    private var records: [String: CorpusContentRecord] = [:]
    var shouldThrowOnFetch = false

    func put(id: String, text: String) {
        let digest = CorpusContentDigest.digest(text)
        let revision: Int64 = (records[id].map { $0.revision } ?? 0) + 1
        records[id] = CorpusContentRecord(
            id: id, revision: revision, digest: digest, text: text)
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        if shouldThrowOnFetch { throw ContentSourceError.forcedError }
        return records[id]
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        // No-op: reindex tests go through activeContentIDs + record(for:),
        // not the change-feed path.
        .empty
    }

    func throwOnNextFetch() {
        shouldThrowOnFetch = true
    }

    private struct ContentSourceError: Error {
        static let forcedError = ContentSourceError()
    }
}

/// Query the SQLite `vector_generations` table to read the current
/// serving_generation for a given modelID. Returns nil if no row exists
/// (which is the canonical initial state — no swap has occurred yet).
private func servingGeneration(storage: any Storage, modelID: String) async throws -> Int64? {
    let rows = try await storage.rowStore.query(
        table: "vector_generations",
        where: .eq(Column(table: "vector_generations", name: "model_id"), .text(modelID)),
        orderBy: [],
        limit: 1,
        offset: nil
    )
    guard let row = rows.first else { return nil }
    // serving_generation is stored as an integer column.
    switch row.values["serving_generation"] {
    case .int(let v): return v
    case .text(let s): return Int64(s)
    default: return nil
    }
}

/// Count ALL rows in `vectors` for a specific model_id, regardless of generation.
/// Includes both serving and pending-reclaim rows.
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

/// Build a CorpusContentEngine with one trainable RI slot.
/// Storage is shared so callers can inspect the underlying tables.
private func makeRIEngine(
    storage: any Storage,
    source: any CorpusContentSource
) async throws -> CorpusContentEngine {
    let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
    let provider = RandomIndexingProvider()
    // No pre-training: the engine trains the basis on first reindex(force:true).
    // indexContent skips vector writes until the basis is persisted; this is
    // normal engine behaviour and is the reason c1 needs two reindex passes.
    return try await CorpusContentEngine(
        storage: storage,
        configuration: config,
        source: source,
        models: [.randomIndexing(provider: provider)]
    )
}

// MARK: - Suite

@Suite("ShadowSwap CorpusContentEngine — c1 generation advance, c2 recall stable, c3 failure path",
       .serialized)
struct ShadowSwapCorpusTests {

    // ── c1: serving_generation advances across two reindex passes ─────────

    /// Two consecutive reindex passes on a corpus with a trainable RI slot:
    ///
    /// Pass 1 (first reindex): The engine has no persisted basis yet, so
    /// indexContent would have skipped RI vectors. reindex trains the basis
    /// (force=true), opens a shadow at gen 1, writes 3 vectors, and publishes.
    /// Result: serving_gen=1, vectorRows=3 (all serving; no prior gen-0 RI
    /// rows to mark pending-reclaim, since indexContent never wrote them).
    ///
    /// Pass 2 (second reindex): The basis is now persisted. reindex opens a
    /// shadow at gen 2, writes 3 new vectors, and publishes. The 3 gen-1
    /// rows are marked pending-reclaim. Total rows = 6 (3 pending + 3 serving).
    ///
    /// This is the canonical superseded-generation cycle verified against the
    /// actual SQLite backend.
    @Test("c1 two reindex passes: serving_generation advances and pending-reclaim rows accumulate")
    func c1_twoReindexPassesAdvanceGenerationAndLeaveReclaimRows() async throws {
        let storage = try makeScratchStorage()
        let source = SimpleContentSource()
        await source.put(id: "item-1", text: "the quick brown fox jumped over the lazy dog")
        await source.put(id: "item-2", text: "machine learning and natural language processing")
        await source.put(id: "item-3", text: "cats and dogs are common household pets")

        let engine = try await makeRIEngine(storage: storage, source: source)
        let modelID = "random-indexing-v1"
        let now = Date(timeIntervalSinceReferenceDate: 22_000_000)

        // ── Pass 1: first shadow swap — trains basis, writes gen-1 vectors ──
        try await engine.reindex(now: now)

        let gen1 = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(gen1 == 1,
            "c1 pass1: serving_generation must be 1 after first reindex (shadow gen 1 published)")

        // In standalone mode the RI slot writes both a binary row (vectorIndex=0)
        // and a float row (vectorIndex=1) per item. 3 items × 2 lanes = 6 rows.
        // No prior gen-0 RI rows existed (indexContent skips untrained slots), so
        // all 6 rows are serving gen-1 with nothing pending-reclaim.
        let rows1 = try await vectorRowCount(storage: storage, modelID: modelID)
        #expect(rows1 == 6,
            "c1 pass1: 6 gen-1 serving rows (2 lanes × 3 items); no prior RI rows to pend-reclaim")

        // ── Pass 2: second shadow swap — gen-1 rows become pending-reclaim ──
        try await engine.reindex(now: now)

        let gen2 = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(gen2 == 2,
            "c1 pass2: serving_generation must be 2 after second reindex")

        // 6 gen-1 rows marked pending-reclaim + 6 gen-2 serving rows = 12 total.
        let rows2 = try await vectorRowCount(storage: storage, modelID: modelID)
        #expect(rows2 == 12,
            "c1 pass2: 12 total rows — 6 gen-1 pending-reclaim + 6 gen-2 serving")
    }

    // ── c2: BM25 recall stable across reindex ────────────────────────────

    /// BM25 lexical recall is unaffected by the shadow swap. The same query
    /// that finds items before reindex must find the same items after. The
    /// swap replaces vector representations only — the inverted index is
    /// rebuilt from the same text, so BM25 scores and coverage are
    /// unchanged.
    @Test("c2 BM25 recall returns the same item set before and after reindex")
    func c2_recallUnchangedAfterReindex() async throws {
        let storage = try makeScratchStorage()
        let source = SimpleContentSource()
        await source.put(id: "recall-a", text: "the quick brown fox jumps over")
        await source.put(id: "recall-b", text: "lazy dog and sunshine in the yard")
        await source.put(id: "recall-c", text: "birds fly high in the morning sky")

        let engine = try await makeRIEngine(storage: storage, source: source)
        let now = Date(timeIntervalSinceReferenceDate: 23_000_000)

        for id in ["recall-a", "recall-b", "recall-c"] {
            try await engine.indexContent(id: id, now: now)
        }

        // Recall before reindex: BM25 is populated by indexContent.
        let before = try await engine.recall("fox", limit: 10, now: now)
        let idsBefore = Set(before.map(\.id))
        #expect(idsBefore.contains("recall-a"),
            "c2: 'fox' must find recall-a before reindex (BM25 in place)")

        // Run the shadow swap.
        try await engine.reindex(now: now)

        // Recall after reindex — BM25 is rebuilt from the same text; must find the same items.
        let after = try await engine.recall("fox", limit: 10, now: now)
        let idsAfter = Set(after.map(\.id))
        #expect(idsAfter == idsBefore,
            "c2: BM25 recall set must be identical before and after the shadow swap reindex")
    }

    // ── c3: failure during reindex leaves prior generation serving ────────

    /// After one successful reindex (serving_gen=1), arming the source to
    /// throw causes the second reindex to fail after beginShadowGeneration
    /// but before publishShadowGeneration. The error propagates and the
    /// serving_generation remains at 1 — the old generation is intact.
    ///
    /// This verifies that publishShadowGeneration is the only commit point:
    /// a failure between beginShadowGeneration and publish leaves the estate
    /// in a safe state (old serving rows unaffected).
    @Test("c3 reindex failure leaves serving_generation at prior value (old generation still serves)")
    func c3_reindexFailureLeavesOldGenerationServing() async throws {
        let storage = try makeScratchStorage()
        let source = SimpleContentSource()
        await source.put(id: "stable-1", text: "the universe is expanding outward")
        await source.put(id: "stable-2", text: "black holes bend spacetime significantly")

        let engine = try await makeRIEngine(storage: storage, source: source)
        let modelID = "random-indexing-v1"
        let now = Date(timeIntervalSinceReferenceDate: 24_000_000)

        // First reindex succeeds — establishes serving_gen=1.
        try await engine.reindex(now: now)
        let genAfterFirst = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(genAfterFirst == 1, "c3: serving_generation is 1 after first successful reindex")

        // Arm the source to throw when the engine fetches records during the
        // second reindex iteration (after beginShadowGeneration, before publish).
        await source.throwOnNextFetch()

        // Second reindex must propagate the error from the source.
        await #expect(throws: (any Error).self) {
            try await engine.reindex(now: now)
        }

        // serving_generation must remain 1 — the prior generation is intact.
        let genAfterFail = try await servingGeneration(storage: storage, modelID: modelID)
        #expect(genAfterFail == 1,
            "c3: serving_generation must remain 1 when second reindex fails before publishShadowGeneration")
    }
}
