// BM25Tests.swift

import XCTest
@testable import CorpusKit
import CorpusKitProviders
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

final class BM25Tests: XCTestCase {

    func makeIndex() -> BM25Index {
        BM25Index(tokenizer: DeterministicTokenizer())
    }

    func makeChunk(_ text: String, _ id: UUID = UUID()) -> Chunk {
        Chunk(
            id: id,
            sourceID: "doc",
            startOffset: 0,
            length: text.count,
            text: text,
            hlc: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1)
        )
    }

    func testEmptyIndexReturnsEmpty() async {
        let idx = makeIndex()
        let results = await idx.search("anything", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testFindsTermInIndexedChunk() async {
        let idx = makeIndex()
        let c1 = makeChunk("the quick brown fox jumps over the lazy dog")
        let c2 = makeChunk("a completely unrelated sentence about cats")
        await idx.index([c1, c2])
        let hits = await idx.search("fox", limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.0, c1.id, "fox-bearing chunk should rank first")
    }

    func testHigherTFRanksHigher() async {
        let idx = makeIndex()
        let c1 = makeChunk("cat cat cat cat cat")
        let c2 = makeChunk("cat and one other thing")
        await idx.index([c1, c2])
        let hits = await idx.search("cat", limit: 5)
        XCTAssertEqual(hits.first?.0, c1.id, "higher TF should rank first")
    }

    func testRemoveCleansPostings() async {
        let idx = makeIndex()
        let c = makeChunk("ephemeral document content")
        await idx.index([c])
        let count1 = await idx.documentCount()
        XCTAssertEqual(count1, 1)
        await idx.remove(c.id)
        let count2 = await idx.documentCount()
        XCTAssertEqual(count2, 0)
        let hits = await idx.search("ephemeral", limit: 5)
        XCTAssertTrue(hits.isEmpty)
    }
}
