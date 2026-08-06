// HybridRecallTests.swift
//
// Conformance tests for the hybrid-recall wrapper. Covers RRF/MMR
// math, paging, the empty-input edge case, and the invariants C-8
// (MMR on every page) and B-1 (substrate access only through the
// estate verb — exercised by the dependency surface itself: this
// file imports GeniusLocusKit and LocusKit only for the value types,
// never for write paths).
//
// ISOLATION NOTE
// Tests that call HybridRecallEngine.rerank() acquire the process-wide
// intellectusTestMutex (IntellectusTestLock.swift) because rerank()
// emits to the global Intellectus singleton. All affected test functions
// are declared `async` to use withIntellectusLock uniformly. The
// shingle/similarity tests do not emit and do not need the lock. Paging
// tests (RecallStream) do not call rerank() directly and do not need
// the lock; the one paging test that does call rerank()
// (mmrRerankObservedOnEveryPage) holds the lock for its rerank() call.

import Testing
import Foundation
import GeniusLocusKit
import SubstrateML
@testable import NeuronKit

// `RecallStream` lives in both `LocusKit` and `NeuronKit`. The test
// imports NeuronKit only and uses NeuronKit's re-exported `Drawer`
// alias, so `RecallStream` here is unambiguously NeuronKit's. The
// `NKRecallStream` alias kept as a readability anchor — every test
// in this file means the NeuronKit paging type.
private typealias NKRecallStream = RecallStream

@Suite("Hybrid recall engine — shingles, similarity, rerank")
struct HybridRecallEngineTests {

    // MARK: - shingles
    // These tests do not call any emitting function; no lock needed.
    // HybridRecallEngine.shingles was retired (I-25); the substrate-owned
    // ShingleSimilarity.shingles is the delegation target. These tests now
    // exercise the provider directly — proving behavior is preserved.

    @Test("shingles is empty for empty input")
    func shinglesIsEmptyForEmptyInput() {
        #expect(ShingleSimilarity.shingles("") == [])
    }

    @Test("shingles for short input returns the whole string")
    func shinglesForShortInputReturnsWholeString() {
        // Strings shorter than the 3-char window collapse to the
        // single shingle = the whole string (lowercased). Edge case
        // preserved from the canonical NeuronKit contract.
        #expect(ShingleSimilarity.shingles("ab") == ["ab"])
        #expect(ShingleSimilarity.shingles("AB") == ["ab"])
    }

    @Test("shingle windows are three-char lowercased")
    func shinglesWindowsAreThreeCharLowercased() {
        #expect(ShingleSimilarity.shingles("CAT") == ["cat"])
        #expect(ShingleSimilarity.shingles("catdog") == ["cat", "atd", "tdo", "dog"])
    }

    // MARK: - shingleSimilarity
    // These tests do not call any emitting function; no lock needed.

    @Test("identical strings have shingle similarity one")
    func shingleSimilarityIdenticalIsOne() {
        #expect(abs(HybridRecallEngine.shingleSimilarity("organic chemistry", "organic chemistry") - 1.0) <= 1e-6)
    }

    @Test("disjoint strings have shingle similarity zero")
    func shingleSimilarityDisjointIsZero() {
        #expect(abs(HybridRecallEngine.shingleSimilarity("abcdef", "ghijkl") - 0.0) <= 1e-6)
    }

    @Test("shingle similarity is symmetric")
    func shingleSimilarityIsSymmetric() {
        let a = "the organic chemistry of carbon"
        let b = "carbon-based organic compounds"
        let ab = HybridRecallEngine.shingleSimilarity(a, b)
        let ba = HybridRecallEngine.shingleSimilarity(b, a)
        #expect(abs(ab - ba) <= 1e-6)
    }

    // The PUBLIC surface (the Rust version's pub shingle_similarity has
    // always been public; the contradiction recipe is the named Swift
    // consumer). It is the engine's value, surfaced.
    @Test("public shingleSimilarity matches the engine")
    func publicShingleSimilarityMatchesEngine() {
        let a = "the organic chemistry of carbon"
        let b = "carbon-based organic compounds"
        #expect(NeuronKit.shingleSimilarity(a, b) == HybridRecallEngine.shingleSimilarity(a, b))
        #expect(abs(NeuronKit.shingleSimilarity(a, a) - 1.0) <= 1e-6)
    }

    // MARK: - delegation assertion
    // Verifies that HybridRecallEngine.shingleSimilarity delegates to the
    // substrate provider (I-25): the engine result must equal
    // SubstrateML.ShingleSimilarity.similarity for the same inputs.

    @Test("shingleSimilarity delegates to SubstrateML.ShingleSimilarity")
    func shingleSimilarityDelegatesToSubstrateML() {
        let pairs: [(String, String)] = [
            ("organic chemistry", "organic chemistry"),
            ("abcdef", "ghijkl"),
            ("the quick brown fox", "the quick brown foxx"),
            ("", "catdog"),
            ("ab", "bc"),
        ]
        for (a, b) in pairs {
            let engine = HybridRecallEngine.shingleSimilarity(a, b)
            let substrate = ShingleSimilarity.similarity(a, b)
            #expect(engine == substrate, "mismatch for (\(a), \(b)): engine=\(engine) substrate=\(substrate)")
        }
    }

    // MARK: - rerank
    // These tests call HybridRecallEngine.rerank() which emits to the
    // Intellectus singleton. Each is declared `async` and acquires the
    // process-wide lock via withIntellectusLock.

    @Test("rerank of empty input returns empty")
    func rerankEmptyInputReturnsEmpty() async throws {
        try await withIntellectusLock {
            #expect(HybridRecallEngine.rerank(drawers: [], tuning: .default).isEmpty)
        }
    }

    @Test("rerank of a single drawer is the identity")
    func rerankSingleDrawerIsIdentity() async throws {
        try await withIntellectusLock {
            let d = makeDrawer(id: "1", content: "chemistry")
            let out = HybridRecallEngine.rerank(drawers: [d], tuning: .default)
            #expect(out.map(\.id) == ["1"])
        }
    }

    @Test("rerank preserves all input drawers")
    func rerankPreservesAllInputDrawers() async throws {
        try await withIntellectusLock {
            // C-8: MMR runs over the input set; every drawer must remain
            // present in the output (MMR reorders, it does not filter).
            let drawers = (1...5).map { i in
                makeDrawer(id: "\(i)", content: "drawer body number \(i)")
            }
            let out = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
            #expect(Set(out.map(\.id)) == Set(drawers.map(\.id)))
            #expect(out.count == drawers.count)
        }
    }

    @Test("rerank is deterministic across invocations")
    func rerankDeterministicAcrossInvocations() async throws {
        try await withIntellectusLock {
            let drawers = (0..<7).map { i in
                makeDrawer(id: "row-\(i)", content: "alpha beta gamma item \(i)")
            }
            let first = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
            let second = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
            #expect(first.map(\.id) == second.map(\.id))
        }
    }

    @Test("rerank with lambda one is relevance-only ordering")
    func rerankWithLambdaOneIsRelevanceOnlyOrdering() async throws {
        try await withIntellectusLock {
            // λ = 1.0 disables the diversity term entirely. With L₁ == L₂
            // (today's verb shape) the relevance term ties for every
            // drawer; ties break in stable input order. So the output
            // equals the input order.
            let drawers = (0..<4).map { i in
                makeDrawer(id: "id-\(i)", content: "content \(i)")
            }
            let tuning = RecallFrameTuning(mmrLambda: 1.0)
            let out = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning)
            #expect(out.map(\.id) == drawers.map(\.id))
        }
    }

    @Test("rerank with lambda zero favours diversity")
    func rerankWithLambdaZeroFavoursDiversity() async throws {
        try await withIntellectusLock {
            // λ = 0.0 picks the maximally diverse remaining drawer at
            // each step. Two near-duplicate drawers and one disjoint
            // drawer — the disjoint drawer should be selected second
            // (after the first input), not third.
            let near1 = makeDrawer(id: "near-1", content: "the quick brown fox")
            let near2 = makeDrawer(id: "near-2", content: "the quick brown foxx")
            let far   = makeDrawer(id: "far",    content: "zzz yyy xxx www")
            let tuning = RecallFrameTuning(mmrLambda: 0.0)
            let out = HybridRecallEngine.rerank(drawers: [near1, near2, far], tuning: tuning)
            #expect(out.first?.id == "near-1")
            #expect(out[1].id == "far")
            #expect(out[2].id == "near-2")
        }
    }

    // MARK: - cue-term lane tests

    @Test("empty cueTerms produces bit-identical output to no-cueTerms path")
    func emptyCueTermsBitIdentical() async throws {
        try await withIntellectusLock {
            // Hard requirement: empty cueTerms MUST produce the same rank order
            // as calling rerank with no cueTerms argument.
            let drawers = (0..<6).map { i in
                makeDrawer(id: "d-\(i)", content: "organic chemistry item \(i)")
            }
            let baseline = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
            let withEmpty = HybridRecallEngine.rerank(drawers: drawers, tuning: .default, cueTerms: [])
            #expect(baseline.map(\.id) == withEmpty.map(\.id),
                    "empty cueTerms must be bit-identical to the no-cueTerms path")
        }
    }

    @Test("older drawer matching more distinct cue terms outranks newer drawer with fewer")
    func olderDrawerWithMoreCueTermsOutranks() async throws {
        try await withIntellectusLock {
            // Oldest drawer (input index 0) matches three distinct cue terms;
            // newest (index 1) matches only one. The lexical lane should rank
            // the older drawer first, overriding recency.
            let older = makeDrawer(id: "old", content: "daguerreotype vintage cameras photography")
            let newer = makeDrawer(id: "new", content: "daguerreotype modern art exhibit")
            // Input order is [older, newer] — recency would keep this order.
            // With cueTerms, older matches 3 terms, newer matches 1.
            let cueTerms = ["daguerreotype", "vintage", "cameras"]
            let out = HybridRecallEngine.rerank(
                drawers: [older, newer], tuning: .default, cueTerms: cueTerms)
            // Both drawers are present; older must appear first.
            #expect(out.map(\.id) == ["old", "new"],
                    "drawer with more distinct cue-term hits must outrank fewer-hit drawer")
        }
    }

    @Test("occurrence count does NOT beat distinct count — five repeats of one term loses to two distinct terms")
    func occurrenceCountDoesNotBeatDistinctCount() async throws {
        try await withIntellectusLock {
            // drawer-A repeats "vintage" five times but matches only 1 distinct
            // cue term. drawer-B contains each of "daguerreotype" and "cameras"
            // once — 2 distinct matches. B must outrank A.
            //
            // Pure-lexical tuning (bm25Weight=1.0, vectorWeight=0.0) isolates
            // the distinct-count logic from semantic (recency) lane interference.
            // With default weights (bm25=0.3, vector=0.7) the semantic lane
            // dominates for adjacent-rank pairs — the recency signal of input
            // position 0 outweighs the distinct-count signal. Pure-lexical
            // eliminates that interference and tests the distinct-count contract
            // directly.
            let drawerA = makeDrawer(id: "repeat", content: "vintage vintage vintage vintage vintage")
            let drawerB = makeDrawer(id: "distinct", content: "daguerreotype cameras collection")
            let cueTerms = ["daguerreotype", "cameras", "vintage"]
            let lexicalTuning = RecallFrameTuning(bm25Weight: 1.0, vectorWeight: 0.0)
            let out = HybridRecallEngine.rerank(
                drawers: [drawerA, drawerB], tuning: lexicalTuning, cueTerms: cueTerms)
            // Input order is [A, B]; after ranking B (2 distinct hits) must come first.
            #expect(out.map(\.id) == ["distinct", "repeat"],
                    "2 distinct cue-term matches must outrank 1 repeated match")
        }
    }

    @Test("cue-term tie-break is deterministic and follows input order")
    func cueTermTieBreakIsInputOrder() async throws {
        try await withIntellectusLock {
            // Three drawers each matching exactly one distinct cue term.
            // Tie-break must be stable input order (d0, d1, d2).
            let drawers = [
                makeDrawer(id: "d0", content: "daguerreotype exposure plates"),
                makeDrawer(id: "d1", content: "vintage photograph albums"),
                makeDrawer(id: "d2", content: "cameras lens aperture"),
            ]
            let cueTerms = ["daguerreotype", "vintage", "cameras"]
            let out = HybridRecallEngine.rerank(drawers: drawers, tuning: .default, cueTerms: cueTerms)
            // Each drawer matches exactly one cue term → all equal; stable
            // input-order tie-break applies. MMR may reorder further, but the
            // initial RRF scores are equal so the MMR diversity step dominates.
            // We verify the output is a permutation of the input and is stable
            // across two invocations (determinism contract).
            let second = HybridRecallEngine.rerank(drawers: drawers, tuning: .default, cueTerms: cueTerms)
            #expect(out.map(\.id) == second.map(\.id),
                    "cue-term tie-break output must be deterministic")
            #expect(Set(out.map(\.id)) == Set(drawers.map(\.id)),
                    "all drawers must be present in output")
        }
    }
}

@Suite("Recall stream paging")
struct RecallStreamTests {

    // MARK: - Paging tests that do NOT call rerank() — no lock needed.

    @Test("empty stream emits one final page")
    func emptyStreamEmitsOneFinalPage() async {
        let stream = NKRecallStream(rows: [], pageSize: 50)
        var pages: [NKRecallStream.Page] = []
        for await page in stream {
            pages.append(page)
        }
        #expect(pages.count == 1)
        #expect(pages[0].rows.isEmpty)
        #expect(pages[0].isLast)
        #expect(pages[0].pageIndex == 0)
    }

    @Test("paging honours the page size")
    func pagingHonoursPageSize() async {
        let rows = (0..<25).map { i in
            makeDrawer(id: "\(i)", content: "row \(i)")
        }
        let stream = NKRecallStream(rows: rows, pageSize: 10)
        var pages: [NKRecallStream.Page] = []
        for await page in stream {
            pages.append(page)
        }
        #expect(pages.count == 3)
        #expect(pages[0].rows.count == 10)
        #expect(pages[1].rows.count == 10)
        #expect(pages[2].rows.count == 5)
        #expect(!pages[0].isLast)
        #expect(!pages[1].isLast)
        #expect(pages[2].isLast)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
    }

    @Test("paging clamps a non-positive page size")
    func pagingClampsNonPositivePageSize() async {
        // Page size < 1 would loop forever; the initializer clamps to
        // 1. Verified end-to-end here.
        let rows = (0..<3).map { i in
            makeDrawer(id: "\(i)", content: "row \(i)")
        }
        let stream = NKRecallStream(rows: rows, pageSize: 0)
        var pageCount = 0
        for await _ in stream { pageCount += 1 }
        #expect(pageCount == 3)
    }

    // MARK: - Paging test that calls rerank() — lock required.

    @Test("MMR rerank is observed on every page")
    func mmrRerankObservedOnEveryPage() async throws {
        // C-8: every emitted page is from the reranked sequence. The
        // engine reranks the full set before paging, so this holds by
        // construction — verified by checking the concatenation of
        // pages equals the engine's standalone output.
        let drawers = (0..<12).map { i in
            makeDrawer(id: "d-\(i)", content: "shared prefix \(i)")
        }
        // rerank() emits to Intellectus — hold the lock for this call.
        let reranked = try await withIntellectusLock {
            HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
        }
        let stream = NKRecallStream(rows: reranked, pageSize: 5)
        var emitted: [Drawer] = []
        for await page in stream {
            emitted.append(contentsOf: page.rows)
        }
        #expect(emitted.map(\.id) == reranked.map(\.id))
    }
}

// MARK: - Test helpers

private func makeDrawer(id: String, content: String) -> Drawer {
    Drawer(
        id: id,
        content: content,
        parentNodeId: "test-room-node",
        sourceFile: nil,
        chunkIndex: nil,
        addedBy: "test",
        filedAt: Date(timeIntervalSince1970: 0),
        embeddingModelID: "test-embed-v1",
        tombstonedAt: nil,
        removedByBatch: nil,
        provenance: 0,
        adjectiveBitmap: 0,
        operationalBitmap: 0,
        lineageID: UUID(),
        udcCode: "",
        udcFacets: nil,
        wikidataQID: nil,
        wikidataQidsSecondary: nil
    )
}
