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
