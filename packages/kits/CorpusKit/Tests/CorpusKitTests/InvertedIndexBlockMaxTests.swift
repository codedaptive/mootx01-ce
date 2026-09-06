// InvertedIndexBlockMaxTests.swift
//
// Block-Max WAND must return the exhaustive top-k — ids AND integer scores —
// on a corpus whose posting lists span several blocks. A block skip that
// carries a list past a live candidate makes that candidate score without the
// list's contribution (a partial score) or drop out entirely; on the ConvoMem
// wing that put the BM25 #2 document at rank 34 and dropped the #1 document.
// Same corpus, seed and expectations as the Rust twin
// (rust/tests/inverted_index_tests.rs `sparse5_bmw_block_skip_keeps_every_contribution`).

import Testing
@testable import CorpusKit

@Suite("InvertedIndex Block-Max WAND block skip")
struct InvertedIndexBlockMaxTests {

    /// Deterministic multi-block corpus: every list is longer than
    /// `invertedIndexBlockSize` (128) so BMW actually skips blocks. Block 0
    /// (d0000..d0127) is rich (large common and medium impacts) so the top-k
    /// threshold is set high early; every later block is poor, so its block-max
    /// bound falls under the threshold and BMW skips it. The rare term carries a
    /// very large impact in three documents, two of them inside poor blocks
    /// (d0400, d0690).
    private static func blockSkipCorpus() -> (InvertedIndex, [(termID: UInt32, queryWeight: Int32)]) {
        // 64-bit LCG (Knuth MMIX constants) so both ports draw the same impacts.
        var state: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        func next(_ lo: Int32, _ hi: Int32) -> Int32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return lo + Int32((state >> 33) % UInt64(hi - lo + 1))
        }
        let docs = 700
        var common: [ImpactPosting] = []
        var medium: [ImpactPosting] = []
        var rare: [ImpactPosting] = []
        for i in 0..<docs {
            let id = String(format: "d%04d", i)
            let rich = i < 128
            common.append(ImpactPosting(itemID: id, impact: rich ? next(50, 60) : next(10, 40)))
            if i % 3 == 0 {
                medium.append(ImpactPosting(itemID: id, impact: rich ? next(140, 150) : next(100, 120)))
            }
            if i == 5 || i == 400 || i == 690 {
                rare.append(ImpactPosting(itemID: id, impact: 900))
            }
        }
        let index = InvertedIndex(postings: [0: common, 1: medium, 2: rare], numDocs: docs)
        let query: [(termID: UInt32, queryWeight: Int32)] = [0, 1, 2].map { ($0, invertedIndexQuantScale) }
        return (index, query)
    }

    /// Failure mode: a block skip strands a list past a live candidate, so BMW
    /// reports d0690/d0400 with partial scores (or misses one) while WAND and
    /// the exhaustive scan agree.
    @Test("BMW equals the exhaustive oracle on ids and scores across block skips")
    func bmwBlockSkipKeepsEveryContribution() {
        let (index, query) = Self.blockSkipCorpus()
        let k = 10
        func key(_ hits: [SparseHit]) -> [String] {
            hits.map { "\($0.itemID):\(Int64(($0.impact * Float(invertedIndexQuantScale)).rounded()))" }
        }
        let scan = key(index.exhaustiveScan(query: query, k: k))
        #expect(key(index.topK(query: query, k: k, algorithm: .wand)) == scan)
        #expect(key(index.topK(query: query, k: k, algorithm: .blockMaxWand)) == scan)
    }
}
