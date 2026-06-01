// BM25Tests.swift

import Testing
import Foundation
import SubstrateTypes
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

@Suite("BM25Index")
struct BM25Tests {

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

    @Test func emptyIndexReturnsEmpty() async {
        let idx = makeIndex()
        let results = await idx.search("anything", limit: 10)
        #expect(results.isEmpty)
    }

    @Test func findsTermInIndexedChunk() async {
        let idx = makeIndex()
        let c1 = makeChunk("the quick brown fox jumps over the lazy dog")
        let c2 = makeChunk("a completely unrelated sentence about cats")
        await idx.index([c1, c2])
        let hits = await idx.search("fox", limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.first?.0 == c1.id, "fox-bearing chunk should rank first")
    }

    @Test func higherTFRanksHigher() async {
        let idx = makeIndex()
        let c1 = makeChunk("cat cat cat cat cat")
        let c2 = makeChunk("cat and one other thing")
        await idx.index([c1, c2])
        let hits = await idx.search("cat", limit: 5)
        #expect(hits.first?.0 == c1.id, "higher TF should rank first")
    }

    @Test func removeCleansPostings() async {
        let idx = makeIndex()
        let c = makeChunk("ephemeral document content")
        await idx.index([c])
        let count1 = await idx.documentCount()
        #expect(count1 == 1)
        await idx.remove(c.id)
        let count2 = await idx.documentCount()
        #expect(count2 == 0)
        let hits = await idx.search("ephemeral", limit: 5)
        #expect(hits.isEmpty)
    }
}
