// HybridRecallTests.swift
//
// Conformance tests for the hybrid-recall wrapper. Covers RRF/MMR
// math, paging, the empty-input edge case, and the invariants C-8
// (MMR on every page) and B-1 (substrate access only through the
// estate verb — exercised by the dependency surface itself: this
// file imports GeniusLocusKit and LocusKit only for the value types,
// never for write paths).

import XCTest
import GeniusLocusKit
@testable import NeuronKit

// `RecallStream` lives in both `LocusKit` and `NeuronKit`. The test
// imports NeuronKit only and uses NeuronKit's re-exported `Drawer`
// alias, so `RecallStream` here is unambiguously NeuronKit's. The
// `NKRecallStream` alias kept as a readability anchor — every test
// in this file means the NeuronKit paging type.
private typealias NKRecallStream = RecallStream

final class HybridRecallEngineTests: XCTestCase {

    // MARK: - shingles

    func testShinglesIsEmptyForEmptyInput() {
        XCTAssertEqual(HybridRecallEngine.shingles(""), [])
    }

    func testShinglesForShortInputReturnsWholeString() {
        // Strings shorter than the 3-char window collapse to the
        // single shingle = the whole string (lowercased). Documented
        // edge case kept identical between Swift and Rust.
        XCTAssertEqual(HybridRecallEngine.shingles("ab"), ["ab"])
        XCTAssertEqual(HybridRecallEngine.shingles("AB"), ["ab"])
    }

    func testShinglesWindowsAreThreeCharLowercased() {
        XCTAssertEqual(
            HybridRecallEngine.shingles("CAT"),
            ["cat"]
        )
        XCTAssertEqual(
            HybridRecallEngine.shingles("catdog"),
            ["cat", "atd", "tdo", "dog"]
        )
    }

    // MARK: - shingleSimilarity

    func testShingleSimilarityIdenticalIsOne() {
        XCTAssertEqual(
            HybridRecallEngine.shingleSimilarity("organic chemistry", "organic chemistry"),
            1.0,
            accuracy: 1e-6
        )
    }

    func testShingleSimilarityDisjointIsZero() {
        XCTAssertEqual(
            HybridRecallEngine.shingleSimilarity("abcdef", "ghijkl"),
            0.0,
            accuracy: 1e-6
        )
    }

    func testShingleSimilarityIsSymmetric() {
        let a = "the organic chemistry of carbon"
        let b = "carbon-based organic compounds"
        let ab = HybridRecallEngine.shingleSimilarity(a, b)
        let ba = HybridRecallEngine.shingleSimilarity(b, a)
        XCTAssertEqual(ab, ba, accuracy: 1e-6)
    }

    // MARK: - rerank

    func testRerankEmptyInputReturnsEmpty() {
        XCTAssertTrue(
            HybridRecallEngine.rerank(drawers: [], tuning: .default).isEmpty
        )
    }

    func testRerankSingleDrawerIsIdentity() {
        let d = makeDrawer(id: "1", content: "chemistry")
        let out = HybridRecallEngine.rerank(drawers: [d], tuning: .default)
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    func testRerankPreservesAllInputDrawers() {
        // C-8: MMR runs over the input set; every drawer must remain
        // present in the output (MMR reorders, it does not filter).
        let drawers = (1...5).map { i in
            makeDrawer(id: "\(i)", content: "drawer body number \(i)")
        }
        let out = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
        XCTAssertEqual(Set(out.map(\.id)), Set(drawers.map(\.id)))
        XCTAssertEqual(out.count, drawers.count)
    }

    func testRerankDeterministicAcrossInvocations() {
        let drawers = (0..<7).map { i in
            makeDrawer(id: "row-\(i)", content: "alpha beta gamma item \(i)")
        }
        let first = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
        let second = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testRerankWithLambdaOneIsRelevanceOnlyOrdering() {
        // λ = 1.0 disables the diversity term entirely. With L₁ == L₂
        // (today's verb shape) the relevance term ties for every
        // drawer; ties break in stable input order. So the output
        // equals the input order.
        let drawers = (0..<4).map { i in
            makeDrawer(id: "id-\(i)", content: "content \(i)")
        }
        let tuning = RecallFrameTuning(mmrLambda: 1.0)
        let out = HybridRecallEngine.rerank(drawers: drawers, tuning: tuning)
        XCTAssertEqual(out.map(\.id), drawers.map(\.id))
    }

    func testRerankWithLambdaZeroFavoursDiversity() {
        // λ = 0.0 picks the maximally diverse remaining drawer at
        // each step. Two near-duplicate drawers and one disjoint
        // drawer — the disjoint drawer should be selected second
        // (after the first input), not third.
        let near1 = makeDrawer(id: "near-1", content: "the quick brown fox")
        let near2 = makeDrawer(id: "near-2", content: "the quick brown foxx")
        let far   = makeDrawer(id: "far",    content: "zzz yyy xxx www")
        let tuning = RecallFrameTuning(mmrLambda: 0.0)
        let out = HybridRecallEngine.rerank(drawers: [near1, near2, far], tuning: tuning)
        XCTAssertEqual(out.first?.id, "near-1")
        XCTAssertEqual(out[1].id, "far")
        XCTAssertEqual(out[2].id, "near-2")
    }
}

final class RecallStreamTests: XCTestCase {

    func testEmptyStreamEmitsOneFinalPage() async {
        let stream = NKRecallStream(rows: [], pageSize: 50)
        var pages: [NKRecallStream.Page] = []
        for await page in stream {
            pages.append(page)
        }
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].rows.isEmpty)
        XCTAssertTrue(pages[0].isLast)
        XCTAssertEqual(pages[0].pageIndex, 0)
    }

    func testPagingHonoursPageSize() async {
        let rows = (0..<25).map { i in
            makeDrawer(id: "\(i)", content: "row \(i)")
        }
        let stream = NKRecallStream(rows: rows, pageSize: 10)
        var pages: [NKRecallStream.Page] = []
        for await page in stream {
            pages.append(page)
        }
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].rows.count, 10)
        XCTAssertEqual(pages[1].rows.count, 10)
        XCTAssertEqual(pages[2].rows.count, 5)
        XCTAssertFalse(pages[0].isLast)
        XCTAssertFalse(pages[1].isLast)
        XCTAssertTrue(pages[2].isLast)
        XCTAssertEqual(pages.map(\.pageIndex), [0, 1, 2])
    }

    func testPagingClampsNonPositivePageSize() async {
        // Page size < 1 would loop forever; the initializer clamps to
        // 1. Verified end-to-end here.
        let rows = (0..<3).map { i in
            makeDrawer(id: "\(i)", content: "row \(i)")
        }
        let stream = NKRecallStream(rows: rows, pageSize: 0)
        var pageCount = 0
        for await _ in stream { pageCount += 1 }
        XCTAssertEqual(pageCount, 3)
    }

    func testMMRRerankObservedOnEveryPage() async {
        // C-8: every emitted page is from the reranked sequence. The
        // engine reranks the full set before paging, so this holds by
        // construction — verified by checking the concatenation of
        // pages equals the engine's standalone output.
        let drawers = (0..<12).map { i in
            makeDrawer(id: "d-\(i)", content: "shared prefix \(i)")
        }
        let reranked = HybridRecallEngine.rerank(drawers: drawers, tuning: .default)
        let stream = NKRecallStream(rows: reranked, pageSize: 5)
        var emitted: [Drawer] = []
        for await page in stream {
            emitted.append(contentsOf: page.rows)
        }
        XCTAssertEqual(emitted.map(\.id), reranked.map(\.id))
    }
}

// MARK: - Test helpers

private func makeDrawer(id: String, content: String) -> Drawer {
    Drawer(
        id: id,
        content: content,
        wing: "test-wing",
        room: "test-room",
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
