// CorpusIndexBitmapTests.swift
//
// Operational bitmap correctness for corpus_index_state.
//
// Covers the six required test axes from the bitmap adoption contract:
//   1. Same-transaction maintenance of bits 1 (has_dense_text) and 2 (lexically_indexed)
//   2. Mask + config predicate truth table (isFullyCovered)
//   3. Generation bump invalidates coverage without estate-wide writes (O(1) invalidation)
//   4. Lazy refresh on recompose (updateBitmap stamps new coverage + generation)
//   5. Wraparound sweep (generation 15 → 0 clears all coverage bits)
//   6. Removed-bit equivalence — activeIndexedStates vs manual filter on mixed fixtures
//
// Axis 1 engine-integration tests use GlobalTestLock (same convention as
// CorpusContentEngineTests) because indexContent emits Intellectus telemetry.
// Axes 2–6 are pure-store or pure-accessor tests with no GlobalTestLock
// requirement.
//
// All storage tests use real SQLite via makeScratchStorage() — the InMemory
// backend does not exercise the column DEFAULT paths that migration compatibility
// depends on.

import Testing
import Foundation
import PersistenceKit
@testable import PersistenceKitSQLite
import CorpusKitProviders

@testable import CorpusKit

// MARK: - Shared fixtures

private let t0 = Date(timeIntervalSince1970: 1_720_000_000)
private let t1 = Date(timeIntervalSince1970: 1_720_001_000)

/// Migrate only the index-state schema and return a live store over real SQLite.
/// Used by tests that exercise the store in isolation (no engine).
private func makeStateStore() async throws -> (CorpusIndexStateStore, any Storage) {
    let storage = try makeScratchStorage()
    try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
    return (CorpusIndexStateStore(storage: storage), storage)
}

/// Insert a minimal active-content checkpoint row directly via the store.
private func insertActiveState(
    store: CorpusIndexStateStore,
    contentID: String,
    bitmap: Int64,
    now: Date = t0
) async throws {
    try await store.advance(CorpusIndexState(
        contentID: contentID, revision: 1, digest: "d-\(contentID)",
        indexVersion: 2, appliedCursor: nil, updatedAt: now,
        operationalBitmap: bitmap))
}

// MARK: - Suite

@Suite("CorpusIndexBitmap", .serialized)
struct CorpusIndexBitmapTests {

    // MARK: - Axis 1: Same-transaction bit maintenance (engine integration)

    /// After `indexContent` completes, the checkpoint must carry
    /// `lexically_indexed=1` and `removed=0`.
    /// The bit must survive an SQLite round-trip and decode correctly.
    @Test func lexicallyIndexedBitSetAfterIndexContent() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let docStore = CorpusDocumentStore(storage: storage)
            let engine = try await CorpusContentEngine(standaloneOn: storage)

            _ = try await docStore.put("Cavendish measured G in 1798.", id: "cav-g", now: t0)
            try await engine.indexContent(id: "cav-g", now: t0)

            // Read directly from the store, bypassing the engine's in-memory state.
            let stateStore = CorpusIndexStateStore(storage: storage)
            let checkpoint = try await stateStore.state(for: "cav-g")
            #expect(checkpoint != nil, "checkpoint must exist after indexContent")
            #expect(checkpoint!.isLexicallyIndexed,
                    "lexically_indexed must be 1 immediately after indexContent")
            #expect(!checkpoint!.isRemoved,
                    "removed must be 0 for freshly indexed content")
        }
    }

    /// `has_dense_text` must be 1 when the record carries a `denseCompositionText`
    /// and 0 when it does not. Both are set in the same transaction as the
    /// BM25 write (the checkpoint bitmap construction path).
    @Test func hasDenseTextBitReflectsDenseCompositionText() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let docStore = CorpusDocumentStore(storage: storage)
            let engine = try await CorpusContentEngine(standaloneOn: storage)
            let stateStore = CorpusIndexStateStore(storage: storage)

            // Record WITHOUT denseCompositionText.
            _ = try await docStore.put("Kelvin defined absolute zero.", id: "kelvin-az", now: t0)
            try await engine.indexContent(id: "kelvin-az", now: t0)

            let cpNoDense = try await stateStore.state(for: "kelvin-az")
            #expect(cpNoDense!.isLexicallyIndexed)
            #expect(!cpNoDense!.hasDenseText,
                    "has_dense_text must be 0 when denseCompositionText is absent")

            // Record WITH denseCompositionText via the dual-text put API.
            _ = try await docStore.put(
                "Boyle's law: pressure times volume is constant.",
                denseCompositionText: "PV = k at constant temperature",
                id: "boyle-law", now: t0)
            try await engine.indexContent(id: "boyle-law", now: t0)

            let cpDense = try await stateStore.state(for: "boyle-law")
            #expect(cpDense!.isLexicallyIndexed)
            #expect(cpDense!.hasDenseText,
                    "has_dense_text must be 1 when denseCompositionText is present")
        }
    }

    // MARK: - Axis 2: Mask + config predicate truth table

    /// `isFullyCovered` must return true exactly when both the coverage mask
    /// covers the requested config slots AND the generation stamp matches.
    /// Tests the full truth table of the predicate.
    @Test func isFullyCoveredTruthTable() {
        // Build a bitmap with generation=3, coverage_mask=K=0,1,2 covered,
        // lexically_indexed=1. Coverage mask as 8-bit sub-field = 0b00000111.
        let gen: Int64 = 3
        var bm = freshCheckpointBitmap()
        for k in 0..<3 {
            bm = CorpusIndexState(
                contentID: "x", revision: 0, digest: "", indexVersion: 2,
                appliedCursor: nil, updatedAt: t0, operationalBitmap: bm
            ).settingCoverageSlot(k, generation: gen)
        }
        let state = CorpusIndexState(
            contentID: "x", revision: 1, digest: "d", indexVersion: 2,
            appliedCursor: nil, updatedAt: t0, operationalBitmap: bm)

        // Sanity: raw field values are correct.
        #expect(state.coverageMask == 0b00000111)
        #expect(state.basisGeneration == gen)
        #expect(state.isLexicallyIndexed)

        // TRUE: exact configMask match with correct generation.
        #expect(state.isFullyCovered(configMask: 0b00000111, currentGeneration: gen))

        // TRUE: strict subset configMask (K=0 only).
        #expect(state.isFullyCovered(configMask: 0b00000001, currentGeneration: gen))

        // TRUE: zero configMask with matching generation (vacuously covered).
        #expect(state.isFullyCovered(configMask: 0, currentGeneration: gen))

        // FALSE: configMask requires K=3 which is not in the coverage mask.
        #expect(!state.isFullyCovered(configMask: 0b00001111, currentGeneration: gen))

        // FALSE: generation mismatch — stale even if mask would otherwise match.
        #expect(!state.isFullyCovered(configMask: 0b00000111, currentGeneration: gen + 1))

        // FALSE: generation mismatch beats a zero configMask.
        #expect(!state.isFullyCovered(configMask: 0, currentGeneration: gen + 1))
    }

    // MARK: - Axis 3: Generation bump invalidates without estate-wide writes

    /// After `incrementBasisGeneration`, existing rows retain their original
    /// bitmap (no writes issued to `corpus_index_state` rows). Their coverage
    /// is invalidated purely because the in-memory generation counter advanced.
    @Test func generationBumpInvalidatesCoverageWithoutRowWrites() async throws {
        let (store, _) = try await makeStateStore()

        // Insert a row covered at generation 0 (K=5, corpus-deterministic).
        var bm = freshCheckpointBitmap()
        bm = CorpusIndexState(
            contentID: "row-det", revision: 0, digest: "", indexVersion: 2,
            appliedCursor: nil, updatedAt: t0, operationalBitmap: bm
        ).settingCoverageSlot(5, generation: 0)
        try await insertActiveState(store: store, contentID: "row-det", bitmap: bm)

        // Covered under generation 0.
        let before = try await store.state(for: "row-det")!
        #expect(before.isFullyCovered(configMask: 0b100000, currentGeneration: 0),
                "must be covered before generation bump")

        // Bump the global generation.
        let gen1 = try await store.incrementBasisGeneration()
        #expect(gen1 == 1)

        // Row bitmap must be UNCHANGED — the O(1) invalidation design tenet.
        let after = try await store.state(for: "row-det")!
        #expect(after.operationalBitmap == before.operationalBitmap,
                "operational_bitmap must not change on generation bump — O(1) invalidation")

        // But coverage reads as stale because the generation stamp no longer matches.
        #expect(!after.isFullyCovered(configMask: 0b100000, currentGeneration: gen1),
                "stale generation stamp must report uncovered under the new generation")
    }

    // MARK: - Axis 4: Lazy refresh on recompose

    /// The backfill path calls `updateBitmap` to stamp new coverage and the
    /// new generation. After the refresh, `isFullyCovered` returns true under
    /// the new generation; other checkpoint fields (revision, digest) are
    /// unchanged.
    @Test func lazyRefreshOnRecomposeStampsNewGeneration() async throws {
        let (store, _) = try await makeStateStore()

        // Insert a row at generation 0, K=2 (corpus-lsa-v1) covered.
        var bm = freshCheckpointBitmap()
        bm = CorpusIndexState(
            contentID: "lsa-row", revision: 7, digest: "dig7", indexVersion: 2,
            appliedCursor: nil, updatedAt: t0, operationalBitmap: bm
        ).settingCoverageSlot(2, generation: 0)
        try await store.advance(CorpusIndexState(
            contentID: "lsa-row", revision: 7, digest: "dig7",
            indexVersion: 2, appliedCursor: nil, updatedAt: t0,
            operationalBitmap: bm))

        // Bump global generation to 1.
        let gen1 = try await store.incrementBasisGeneration()
        #expect(gen1 == 1)
        let stale = try await store.state(for: "lsa-row")!
        #expect(!stale.isFullyCovered(configMask: 0b00100, currentGeneration: gen1),
                "must be stale after generation bump")

        // Simulate the backfill path: read current state, stamp new slot + generation.
        let refreshed = stale.settingCoverageSlot(2, generation: gen1)
        try await store.updateBitmap(contentID: "lsa-row", bitmap: refreshed)

        // After the lazy refresh, revision and digest are unchanged.
        let after = try await store.state(for: "lsa-row")!
        #expect(after.revision == 7, "revision must be preserved by updateBitmap")
        #expect(after.digest == "dig7", "digest must be preserved by updateBitmap")

        // Coverage is now valid under gen 1.
        #expect(after.isFullyCovered(configMask: 0b00100, currentGeneration: gen1),
                "lazy-refreshed row must report covered under the new generation")

        // Still stale under generation 0.
        #expect(!after.isFullyCovered(configMask: 0b00100, currentGeneration: 0),
                "row must report stale under the OLD generation after a gen-1 refresh")
    }

    // MARK: - Axis 5: Wraparound sweep

    /// When the generation counter wraps from 15 to 0, `resetGenerationSweep`
    /// clears all coverage bits and generation stamps from every content row.
    /// After the sweep every row reads as uncovered; `lexically_indexed` is
    /// preserved (the sweep targets only bits 4–15).
    @Test func wraparoundSweepClearsAllCoverageBits() async throws {
        let (store, _) = try await makeStateStore()

        // row-a: K=0 covered at gen=0.
        var bmA = freshCheckpointBitmap()
        bmA = CorpusIndexState(contentID: "row-a", revision: 0, digest: "", indexVersion: 2,
                               appliedCursor: nil, updatedAt: t0, operationalBitmap: bmA)
            .settingCoverageSlot(0, generation: 0)
        try await insertActiveState(store: store, contentID: "row-a", bitmap: bmA)

        // row-b: K=2 + K=5 covered at gen=0.
        var bmB = freshCheckpointBitmap()
        bmB = CorpusIndexState(contentID: "row-b", revision: 0, digest: "", indexVersion: 2,
                               appliedCursor: nil, updatedAt: t0, operationalBitmap: bmB)
            .settingCoverageSlot(2, generation: 0)
        bmB = CorpusIndexState(contentID: "row-b", revision: 0, digest: "", indexVersion: 2,
                               appliedCursor: nil, updatedAt: t0, operationalBitmap: bmB)
            .settingCoverageSlot(5, generation: 0)
        try await insertActiveState(store: store, contentID: "row-b", bitmap: bmB)

        // row-c: lexically_indexed=1, no coverage.
        try await insertActiveState(
            store: store, contentID: "row-c", bitmap: freshCheckpointBitmap())

        // Pump the generation counter to 15.
        var gen: Int64 = 0
        for _ in 0..<15 { gen = try await store.incrementBasisGeneration() }
        #expect(gen == 15, "must reach 15 before wraparound")

        // Wrap to 0.
        let afterWrap = try await store.incrementBasisGeneration()
        #expect(afterWrap == 0, "generation must wrap to 0 after 15")

        // Execute the sweep.
        try await store.resetGenerationSweep()

        // Global counter is 0.
        #expect(try await store.basisGeneration() == 0,
                "global generation must be 0 after sweep")

        // All content rows: coverage_mask=0, basisGeneration=0,
        // lexically_indexed preserved, not covered under any config.
        for id in ["row-a", "row-b", "row-c"] {
            let s = try await store.state(for: id)!
            #expect(s.coverageMask == 0,
                    "coverage_mask must be 0 after sweep for \(id)")
            #expect(s.basisGeneration == 0,
                    "generation stamp must be 0 after sweep for \(id)")
            #expect(s.isLexicallyIndexed,
                    "lexically_indexed must survive the sweep for \(id)")
            #expect(!s.isFullyCovered(configMask: 0b111111, currentGeneration: 0),
                    "all rows must be uncovered immediately after sweep for \(id)")
        }
    }

    // MARK: - Axis 6: Removed-bit equivalence on mixed fixtures

    /// `activeIndexedStates()` must return exactly the rows where
    /// `isLexicallyIndexed == true && isRemoved == false`, and must agree
    /// with a manual filter of `allStates()` on a fixture containing active,
    /// removed, feed-cursor, and never-indexed rows.
    @Test func removedBitEquivalenceOnMixedFixture() async throws {
        let (store, _) = try await makeStateStore()

        // active1: lexically_indexed=1, removed=0 — MUST appear.
        try await insertActiveState(
            store: store, contentID: "active1", bitmap: freshCheckpointBitmap())

        // active2: lexically_indexed=1, removed=0, plus K=1 coverage — MUST appear.
        var bmActive2 = freshCheckpointBitmap()
        bmActive2 = CorpusIndexState(contentID: "active2", revision: 0, digest: "", indexVersion: 2,
                                     appliedCursor: nil, updatedAt: t0, operationalBitmap: bmActive2)
            .settingCoverageSlot(1, generation: 0)
        try await insertActiveState(store: store, contentID: "active2", bitmap: bmActive2)

        // removed1: first insert as active, then soft-remove — must NOT appear.
        try await insertActiveState(
            store: store, contentID: "removed1", bitmap: freshCheckpointBitmap())
        try await store.softRemove(contentID: "removed1", now: t1)

        // feed-cursor sentinel: operational_bitmap=0 (no lifecycle bits) — must NOT appear.
        try await store.advance(CorpusIndexState(
            contentID: "\u{1F}feed",
            revision: 0, digest: "", indexVersion: 2,
            appliedCursor: "cursor-42", updatedAt: t0,
            operationalBitmap: 0))   // feedCursorBitmap = 0

        // never-indexed: operational_bitmap=0, never went through the engine — must NOT appear.
        try await store.advance(CorpusIndexState(
            contentID: "no-index",
            revision: 0, digest: "", indexVersion: 2,
            appliedCursor: nil, updatedAt: t0,
            operationalBitmap: 0))

        // activeIndexedStates must return exactly {active1, active2}.
        let active = try await store.activeIndexedStates()
        let activeIDs = Set(active.map(\.contentID))
        #expect(activeIDs == ["active1", "active2"],
                "activeIndexedStates must return only non-removed lexically-indexed rows")

        // Manual filter of allStates must agree.
        let all = try await store.allStates()
        let manualIDs = Set(
            all.filter { $0.isLexicallyIndexed && !$0.isRemoved }.map(\.contentID))
        #expect(activeIDs == manualIDs,
                "activeIndexedStates must agree with manual isLexicallyIndexed && !isRemoved filter")

        // Verify the removed row has the correct tombstone state.
        let removedState = try await store.state(for: "removed1")
        #expect(removedState != nil, "soft-removed row must be retained as a tombstone")
        #expect(removedState!.isRemoved, "removed flag must be 1")
        #expect(!removedState!.isLexicallyIndexed, "lexically_indexed must be 0")
        #expect(removedState!.revision == 0, "revision must be reset to 0")
        #expect(removedState!.digest == "", "digest must be reset to empty")

        // Verify the feed-cursor sentinel carries a zero bitmap.
        let feedState = try await store.state(for: "\u{1F}feed")
        #expect(feedState?.operationalBitmap == 0,
                "feed-cursor sentinel must carry operational_bitmap=0")
        #expect(feedState?.isLexicallyIndexed == false,
                "feed-cursor sentinel must not appear lexically indexed")
    }

    // MARK: - Store: basis-generation counter semantics

    /// `basisGeneration()` returns 0 before any retrain (no singleton row),
    /// increments monotonically, and wraps at 16.
    @Test func basisGenerationCounterWrapsAt16() async throws {
        let (store, _) = try await makeStateStore()

        // No singleton row: returns 0.
        #expect(try await store.basisGeneration() == 0)

        // Increment 1 → 1.
        let g1 = try await store.incrementBasisGeneration()
        #expect(g1 == 1)
        #expect(try await store.basisGeneration() == 1, "basisGeneration must persist")

        // Pump to 14.
        for _ in 2...14 { _ = try await store.incrementBasisGeneration() }
        #expect(try await store.basisGeneration() == 14)

        // 14 → 15.
        let g15 = try await store.incrementBasisGeneration()
        #expect(g15 == 15)

        // 15 → 0 (modulo 16 wraparound).
        let g0 = try await store.incrementBasisGeneration()
        #expect(g0 == 0, "generation must wrap to 0 from 15")
        #expect(try await store.basisGeneration() == 0)

        // Continue from 0.
        let g1again = try await store.incrementBasisGeneration()
        #expect(g1again == 1)
    }

    // MARK: - Accessor unit tests (no storage)

    /// Verifies the mask/shift arithmetic in `settingCoverageSlot`,
    /// `clearingCoverageAndGeneration`, and the bit-field accessors is
    /// correct in pure Swift without any persistence layer.
    @Test func bitmapFieldAccessorMathIsCorrect() {
        let gen: Int64 = 7
        // Build a bitmap: lexically_indexed=1, K=1+2+4 covered, generation=7.
        var bm = freshCheckpointBitmap()
        for k in [1, 2, 4] {
            bm = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                  appliedCursor: nil, updatedAt: t0, operationalBitmap: bm)
                .settingCoverageSlot(k, generation: gen)
        }
        let state = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                     appliedCursor: nil, updatedAt: t0, operationalBitmap: bm)

        // coverage_mask: K=1,2,4 → bits 5,6,8 → 8-bit sub-field = 0b00010110 = 0x16
        #expect(state.coverageMask == 0b00010110)
        #expect(state.basisGeneration == gen)
        #expect(state.isLexicallyIndexed)
        #expect(!state.isRemoved)
        #expect(!state.hasDenseText)

        // clearingCoverageAndGeneration resets bits 4–15 only;
        // lexically_indexed (bit 2) survives.
        let clearedBm = state.clearingCoverageAndGeneration()
        let cleared = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                       appliedCursor: nil, updatedAt: t0, operationalBitmap: clearedBm)
        #expect(cleared.coverageMask == 0)
        #expect(cleared.basisGeneration == 0)
        #expect(cleared.isLexicallyIndexed, "lexically_indexed survives clearingCoverageAndGeneration")
        #expect(!cleared.isRemoved)

        // softRemovedBitmap: removed=1, lexically_indexed=0, coverage=0.
        let removedState = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                            appliedCursor: nil, updatedAt: t0,
                                            operationalBitmap: softRemovedBitmap())
        #expect(removedState.isRemoved)
        #expect(!removedState.isLexicallyIndexed)
        #expect(removedState.coverageMask == 0)
        #expect(removedState.basisGeneration == 0)

        // Generation wraps correctly in settingCoverageSlot (modulo 16).
        let genOver = Int64(17)   // 17 % 16 = 1
        let wrappedBm = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                         appliedCursor: nil, updatedAt: t0,
                                         operationalBitmap: freshCheckpointBitmap())
            .settingCoverageSlot(0, generation: genOver)
        let wrappedState = CorpusIndexState(contentID: "x", revision: 0, digest: "", indexVersion: 2,
                                            appliedCursor: nil, updatedAt: t0,
                                            operationalBitmap: wrappedBm)
        #expect(wrappedState.basisGeneration == 1,
                "generation must be stored modulo 16 (17 % 16 == 1)")
    }
}
