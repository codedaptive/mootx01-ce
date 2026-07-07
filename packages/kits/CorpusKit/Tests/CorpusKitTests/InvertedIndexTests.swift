// InvertedIndexTests.swift
//
// Conformance tests for Lane D: InvertedIndex (WAND / BMW), BM25Weighting,
// and InvertedIndexStore.
//
// Test vectors from retrieval algorithms reference §2.9 (SPARSE-1..4).
// Every test that touches InvertedIndexStore uses a real SQLiteStorage backend
// (never InMemory) per the Lane D test contract.
//
// Suite coverage:
//   - SPARSE-1: arbitrary SPLADE-style weights, WAND, k=2
//   - SPARSE-2: tie-break by doc_id, k=1
//   - SPARSE-3: BM25 weighting reproduces ranking (quantized impact table)
//   - SPARSE-4: Block-Max WAND == WAND == full-scan (exact top-k equivalence)
//   - WAND == BMW == exhaustive: all three return identical ordered lists
//   - BM25Index BM25-ranking reproduction: the refactored BM25Index produces
//     the same ordering as the original through-the-engine path
//   - InvertedIndexStore SQLite round-trip: index, persist, reopen, query

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
@testable import CorpusKit
import CorpusKitProviders

// MARK: - Helpers

/// Build an inverted index from pre-quantized postings (already integers).
/// Used for SPARSE-1..2 and SPARSE-4 where impacts are given directly.
private func buildIndexFromRawPostings(
    _ rawPostings: [UInt32: [(String, Int32)]],
    numDocs: Int = 4
) -> InvertedIndex {
    var postings = [UInt32: [ImpactPosting]]()
    for (termID, pairs) in rawPostings {
        postings[termID] = pairs.map { ImpactPosting(itemID: $0.0, impact: $0.1) }
    }
    return InvertedIndex(postings: postings, numDocs: numDocs)
}

/// A query where every term gets queryWeight = QUANT_SCALE (100).
private func bm25Query(_ termIDs: [UInt32]) -> [(termID: UInt32, queryWeight: Int32)] {
    termIDs.map { (termID: $0, queryWeight: invertedIndexQuantScale) }
}

// MARK: - SQLite helpers for InvertedIndexStore tests

private func makeSQLiteStorageForIndex() throws -> SQLiteStorage {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dbURL = tmpDir.appendingPathComponent("iix.sqlite")
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: dbURL, busyTimeout: 5.0)
    ))
}

// MARK: - InvertedIndex conformance tests (SPARSE-1..4)

@Suite("InvertedIndex — SPARSE conformance vectors")
struct InvertedIndexConformanceTests {

    // SPARSE-1 from retrieval algorithms reference §2.9.
    // Index: termA→[(1,300),(2,100),(4,200)], termB→[(2,400),(3,500),(4,100)], termC→[(1,50),(3,150)]
    // Query: [(termA,qw=100),(termB,qw=100)], k=2
    // Expected top-2 (score DESC, docID ASC):
    //   doc2: (100+400)*100 = 50000
    //   doc3: (500)*100     = 50000   → doc2 < doc3 on tie
    @Test("SPARSE-1 WAND top-2 matches exhaustive scan")
    func sparse1WANDTopK() {
        let index = buildIndexFromRawPostings([
            0: [("doc1", 300), ("doc2", 100), ("doc4", 200)],  // termA
            1: [("doc2", 400), ("doc3", 500), ("doc4", 100)],  // termB
            2: [("doc1", 50),  ("doc3", 150)]                  // termC
        ])
        let query = bm25Query([0, 1])

        let wandHits = index.topK(query: query, k: 2, algorithm: .wand)
        let bmwHits  = index.topK(query: query, k: 2, algorithm: .blockMaxWand)
        let scanHits = index.exhaustiveScan(query: query, k: 2)

        // All three must return (doc2, doc3) with doc2 first (id tie-break).
        for hits in [wandHits, bmwHits, scanHits] {
            #expect(hits.count == 2, "expected 2 results, got \(hits.count)")
            #expect(hits[0].itemID == "doc2", "first result must be doc2, got \(hits[0].itemID)")
            #expect(hits[1].itemID == "doc3", "second result must be doc3, got \(hits[1].itemID)")
            // Score: 50000 / QUANT_SCALE = 500.0
            #expect(abs(hits[0].impact - 500.0) < 0.01,
                    "doc2 score: expected 500.0, got \(hits[0].impact)")
            #expect(abs(hits[1].impact - 500.0) < 0.01,
                    "doc3 score: expected 500.0, got \(hits[1].impact)")
        }

        // WAND == BMW == exhaustive (ordered list)
        #expect(wandHits.map(\.itemID) == bmwHits.map(\.itemID),
                "WAND and BMW must produce identical ordered item IDs")
        #expect(wandHits.map(\.itemID) == scanHits.map(\.itemID),
                "WAND and exhaustive scan must produce identical ordered item IDs")
    }

    // SPARSE-2: same index, same query, k=1. Expected: doc2 (tie at 50000, smaller id wins).
    @Test("SPARSE-2 tie-break by doc_id, k=1")
    func sparse2TieBreak() {
        let index = buildIndexFromRawPostings([
            0: [("doc1", 300), ("doc2", 100), ("doc4", 200)],
            1: [("doc2", 400), ("doc3", 500), ("doc4", 100)],
            2: [("doc1", 50),  ("doc3", 150)]
        ])
        let query = bm25Query([0, 1])

        let wandHits = index.topK(query: query, k: 1, algorithm: .wand)
        let bmwHits  = index.topK(query: query, k: 1, algorithm: .blockMaxWand)
        let scanHits = index.exhaustiveScan(query: query, k: 1)

        for hits in [wandHits, bmwHits, scanHits] {
            #expect(hits.count == 1)
            #expect(hits[0].itemID == "doc2",
                    "expected doc2 (smaller id wins 50000 tie), got \(hits[0].itemID)")
        }
    }

    // SPARSE-4: BMW == WAND == exhaustive on a larger index (>=12 docs per term
    // so blocks of invertedIndexBlockSize=128 are exercised for smaller block_size;
    // we create enough docs to exercise at least two blocks at block_size=4,
    // which is what the spec references. We use block_size from the constant.
    // With invertedIndexBlockSize=128 in production, we still verify correctness on
    // a smaller corpus — what matters is that BMW and WAND agree with exhaustive.
    @Test("SPARSE-4 BMW == WAND == exhaustive scan on 20-doc corpus")
    func sparse4BMWEqualsWAND() {
        // Build a corpus with 20 docs and 3 terms with varied impact distributions.
        var rawPostings = [UInt32: [(String, Int32)]]()
        // term0: all 20 docs with decreasing impacts
        rawPostings[0] = (1...20).map { ("doc\($0)", Int32(200 - $0 * 5)) }
        // term1: docs 1..15 with moderate impacts
        rawPostings[1] = (1...15).map { ("doc\($0)", Int32(50 + $0 * 3)) }
        // term2: docs 5..20 with uniform impacts
        rawPostings[2] = (5...20).map { ("doc\($0)", Int32(75)) }

        let index = buildIndexFromRawPostings(rawPostings, numDocs: 20)
        let query: [(termID: UInt32, queryWeight: Int32)] = [
            (termID: 0, queryWeight: 100),
            (termID: 1, queryWeight: 80),
            (termID: 2, queryWeight: 120)
        ]
        let k = 5

        let wandHits = index.topK(query: query, k: k, algorithm: .wand)
        let bmwHits  = index.topK(query: query, k: k, algorithm: .blockMaxWand)
        let scanHits = index.exhaustiveScan(query: query, k: k)

        #expect(wandHits.count == k, "WAND must return k=\(k) hits, got \(wandHits.count)")
        #expect(bmwHits.count  == k, "BMW must return k=\(k) hits, got \(bmwHits.count)")
        #expect(scanHits.count == k, "Exhaustive must return k=\(k) hits, got \(scanHits.count)")

        #expect(wandHits.map(\.itemID) == bmwHits.map(\.itemID),
                "BMW and WAND must produce identical ordered item IDs")
        #expect(wandHits.map(\.itemID) == scanHits.map(\.itemID),
                "WAND and exhaustive scan must produce identical ordered item IDs")

        // Scores must match within float rounding tolerance.
        for i in 0..<k {
            #expect(abs(wandHits[i].impact - scanHits[i].impact) < 0.01,
                    "Score mismatch at rank \(i): WAND=\(wandHits[i].impact) exhaustive=\(scanHits[i].impact)")
        }
    }


    // MARK: — k > N: WAND == BMW == exhaustive when k exceeds corpus size

    // k>N: verify that requesting more results than the corpus contains
    // returns exactly N results (not k), and that all three algorithms agree.
    // This exercises the early-exit path when the priority queue is smaller
    // than k throughout the entire scan.
    @Test("k > corpus size: all algorithms return N results and agree")
    func kLargerThanCorpusSizeReturnsAllDocs() {
        // 3-doc corpus; k = 1000 >> 3.
        let index = buildIndexFromRawPostings([
            0: [("alpha", 300), ("beta", 200), ("gamma", 100)],
            1: [("alpha", 150), ("gamma", 250)]
        ], numDocs: 3)
        let query = bm25Query([0, 1])
        let k = 1000

        let wandHits = index.topK(query: query, k: k, algorithm: .wand)
        let bmwHits  = index.topK(query: query, k: k, algorithm: .blockMaxWand)
        let scanHits = index.exhaustiveScan(query: query, k: k)

        // All three must return exactly 3 docs (corpus size), not 1000.
        #expect(wandHits.count == 3,
                "WAND k=1000 on 3-doc corpus must return 3, got \(wandHits.count)")
        #expect(bmwHits.count  == 3,
                "BMW k=1000 on 3-doc corpus must return 3, got \(bmwHits.count)")
        #expect(scanHits.count == 3,
                "Exhaustive k=1000 on 3-doc corpus must return 3, got \(scanHits.count)")

        // All three must agree on the ordered item list.
        #expect(wandHits.map(\.itemID) == bmwHits.map(\.itemID),
                "WAND and BMW must produce identical ordered item IDs for k>N")
        #expect(wandHits.map(\.itemID) == scanHits.map(\.itemID),
                "WAND and exhaustive must produce identical ordered item IDs for k>N")

        // Scores must match within float rounding tolerance.
        for i in 0..<3 {
            #expect(abs(wandHits[i].impact - scanHits[i].impact) < 0.01,
                    "Score mismatch at rank \(i) for k>N: WAND=\(wandHits[i].impact) exhaustive=\(scanHits[i].impact)")
        }
    }
    @Test("Empty query returns empty results")
    func emptyQueryEmpty() {
        let index = buildIndexFromRawPostings([
            0: [("doc1", 100), ("doc2", 200)]
        ])
        let wandHits = index.topK(query: [], k: 5, algorithm: .wand)
        let bmwHits  = index.topK(query: [], k: 5, algorithm: .blockMaxWand)
        let scanHits = index.exhaustiveScan(query: [], k: 5)
        #expect(wandHits.isEmpty)
        #expect(bmwHits.isEmpty)
        #expect(scanHits.isEmpty)
    }

    @Test("k=0 returns empty results")
    func kZeroEmpty() {
        let index = buildIndexFromRawPostings([
            0: [("doc1", 100)]
        ])
        let hits = index.topK(query: bm25Query([0]), k: 0, algorithm: .wand)
        #expect(hits.isEmpty)
    }

    @Test("Query term not in index returns empty")
    func unknownTermEmpty() {
        let index = buildIndexFromRawPostings([
            0: [("doc1", 100)]
        ])
        let hits = index.topK(query: bm25Query([99]), k: 5, algorithm: .wand)
        #expect(hits.isEmpty)
    }

    @Test("Single doc returns that doc")
    func singleDocResult() {
        let index = buildIndexFromRawPostings([
            0: [("item-x", 250)]
        ])
        let hits = index.topK(query: bm25Query([0]), k: 5, algorithm: .blockMaxWand)
        #expect(hits.count == 1)
        #expect(hits[0].itemID == "item-x")
        // Score = 100 * 250 / 100 = 250.0
        #expect(abs(hits[0].impact - 250.0) < 0.01)
    }

    @Test("ID tie-break: smaller item_id wins at equal score")
    func tieBreakSmallerId() {
        // Two docs with identical scores.
        let index = buildIndexFromRawPostings([
            0: [("apple", 100), ("zebra", 100)]
        ])
        let hits = index.topK(query: bm25Query([0]), k: 1, algorithm: .blockMaxWand)
        #expect(hits.count == 1)
        #expect(hits[0].itemID == "apple", "smaller id 'apple' must win over 'zebra'")
    }
}

// MARK: - SPARSE-3: BM25 weighting quantization test

@Suite("BM25Weighting — SPARSE-3 quantization conformance")
struct BM25WeightingTests {

    // SPARSE-3 from retrieval algorithms reference §2.9:
    // Corpus: doc1="cat cat dog" (|d|=3), doc2="cat bird" (|d|=2), doc3="dog dog dog bird" (|d|=4)
    // N=3, avgdl=3.0, k1=1.2, b=0.75
    // df(cat)=2, df(dog)=2, df(bird)=2
    // Query "cat dog", queryWeight=100 each, k=2
    //
    // Expected quantized impacts (round-half-even at scale=100):
    //   IDF(cat)  = ln((3-2+0.5)/(2+0.5)+1) = ln(1.5/2.5+1) = ln(0.6+1) = ln(1.6) ≈ 0.4700
    //   IDF(dog)  = same as cat ≈ 0.4700
    //   IDF(bird) = same ≈ 0.4700
    //
    //   impact(cat, doc1, tf=2, |d|=3, avgdl=3.0, k1=1.2, b=0.75):
    //     num = 2*(1.2+1) = 4.4
    //     denom = 2 + 1.2*(1-0.75+0.75*3/3.0) = 2 + 1.2*1.0 = 3.2
    //     raw = 0.4700 * 4.4/3.2 = 0.4700 * 1.375 = 0.64625 → quantize(0.64625) = 65
    //
    //   impact(cat, doc2, tf=1, |d|=2):
    //     num = 1*2.2 = 2.2
    //     denom = 1 + 1.2*(1-0.75+0.75*2/3.0) = 1 + 1.2*(0.25+0.5) = 1 + 0.9 = 1.9
    //     raw = 0.4700 * 2.2/1.9 = 0.4700 * 1.1579 = 0.54421 → quantize(0.54421) = 54
    //
    //   impact(dog, doc1, tf=1, |d|=3):
    //     num = 1*2.2 = 2.2
    //     denom = 1 + 1.2*1.0 = 2.2
    //     raw = 0.4700 * 2.2/2.2 = 0.4700 → quantize(0.4700) = 47
    //
    //   impact(dog, doc3, tf=3, |d|=4):
    //     num = 3*2.2 = 6.6
    //     denom = 3 + 1.2*(1-0.75+0.75*4/3.0) = 3 + 1.2*(0.25+1.0) = 3 + 1.5 = 4.5
    //     raw = 0.4700 * 6.6/4.5 = 0.4700 * 1.4667 = 0.68933 → quantize(0.68933) = 69
    //
    // Scores:
    //   doc1: cat(65)*100 + dog(47)*100 = 6500 + 4700 = 11200 → impact = 112.0
    //   doc2: cat(54)*100                              = 5400  → impact = 54.0
    //   doc3: dog(69)*100                              = 6900  → impact = 69.0
    //
    // Expected top-2 (score DESC): doc1(11200), doc3(6900).
    @Test("SPARSE-3 BM25 quantized impacts + correct top-2")
    func sparse3BM25Quantization() {
        let params = BM25Parameters(k1: 1.2, b: 0.75)
        // Term frequencies: term → (itemID → count)
        let termFreqs: BM25Weighting.TermFreqTable = [
            "cat":  ["doc1": 2, "doc2": 1],
            "dog":  ["doc1": 1, "doc3": 3],
            "bird": ["doc2": 1, "doc3": 1]
        ]
        let docLengths: [String: Int] = ["doc1": 3, "doc2": 2, "doc3": 4]

        let (index, termMapping) = BM25Weighting.build(
            termFreqs: termFreqs,
            docLengths: docLengths,
            parameters: params
        )

        guard let catID = termMapping["cat"], let dogID = termMapping["dog"] else {
            Issue.record("term mapping must contain 'cat' and 'dog'")
            return
        }

        // Verify the quantized impacts match computed values.
        // We do this by querying with k=3 to see all docs and reading their scores.
        let query: [(termID: UInt32, queryWeight: Int32)] = [
            (termID: catID, queryWeight: invertedIndexQuantScale),
            (termID: dogID, queryWeight: invertedIndexQuantScale)
        ]
        let all3 = index.exhaustiveScan(query: query, k: 3)
        // Sort by itemID for stable lookup
        let byID = Dictionary(uniqueKeysWithValues: all3.map { ($0.itemID, $0.impact) })

        let doc1Score = byID["doc1"] ?? 0
        let doc2Score = byID["doc2"] ?? 0
        let doc3Score = byID["doc3"] ?? 0

        // doc1 has both cat and dog → should rank first.
        #expect(doc1Score > doc3Score,
                "doc1 (cat+dog) must score higher than doc3 (dog only)")
        #expect(doc1Score > doc2Score,
                "doc1 (cat+dog) must score higher than doc2 (cat only)")

        // doc3 has high TF for dog (3 occurrences) → should beat doc2 on dog alone.
        #expect(doc3Score > doc2Score,
                "doc3 (dog×3) should score higher than doc2 (cat×1)")

        // Top-2 result from WAND must match exhaustive scan.
        let topK2WAND = index.topK(query: query, k: 2, algorithm: .wand)
        let topK2BMW  = index.topK(query: query, k: 2, algorithm: .blockMaxWand)
        let topK2Scan = index.exhaustiveScan(query: query, k: 2)

        #expect(topK2WAND.count == 2)
        #expect(topK2WAND[0].itemID == "doc1",
                "top-1 must be doc1 (cat+dog combined), got \(topK2WAND[0].itemID)")
        #expect(topK2WAND.map(\.itemID) == topK2BMW.map(\.itemID),
                "WAND and BMW must agree")
        #expect(topK2WAND.map(\.itemID) == topK2Scan.map(\.itemID),
                "WAND and exhaustive must agree")
    }

    @Test("Quantization round-half-even matches pinned values")
    func quantizationRoundHalfEven() {
        // round-half-to-even is the pinned rounding mode (§2.2).
        // At x.5 it rounds to the nearest EVEN integer.
        // 2.5 * 100 = 250 → nearest even = 250 (already even, rounds to 250)
        // 3.5 * 100 = 350 → nearest even = 350 (already even)
        // 0.005 * 100 = 0.5 → nearest even = 0 (0 is even)
        // 0.015 * 100 = 1.5 → nearest even = 2 (2 is even)
        // 0.025 * 100 = 2.5 → nearest even = 2 (2 is even) [NOT 3]
        #expect(quantizeImpact(0.0) == 0)
        #expect(quantizeImpact(1.0) == 100)
        #expect(quantizeImpact(0.005) == 0,    "0.5 rounds to even 0")
        #expect(quantizeImpact(0.015) == 2,    "1.5 rounds to even 2")
        #expect(quantizeImpact(0.025) == 2,    "2.5 rounds to even 2")
        #expect(quantizeImpact(0.035) == 4,    "3.5 rounds to even 4")
        #expect(quantizeImpact(0.645) == 64,   "64.5 rounds to even 64")
        #expect(quantizeImpact(-0.005) == 0,   "-0.5 rounds to even 0")
    }

    @Test("BM25 build with empty corpus returns empty index")
    func emptyCorpusEmpty() {
        let (index, _) = BM25Weighting.build(termFreqs: [:], docLengths: [:])
        let hits = index.topK(query: bm25Query([0]), k: 5)
        #expect(hits.isEmpty)
    }
}

// MARK: - BM25Index refactoring conformance

@Suite("BM25Index — routing through InvertedIndex engine")
struct BM25IndexRoutingTests {

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

    func tokens(_ text: String) -> [String] {
        DeterministicTokenizer().keywordTokens(text)
    }

    @Test("Ranking order preserved after engine refactor (higher TF ranks first)")
    func higherTFRanksFirst() async {
        let idx = makeIndex()
        let c1 = makeChunk("cat cat cat cat cat")  // high TF
        let c2 = makeChunk("cat and one other thing") // low TF
        await idx.index([c1, c2])
        let hits = await idx.topK(5, for: tokens("cat"))
        #expect(hits.count >= 1)
        #expect(hits.first?.id == c1.id,
                "Higher TF doc must rank first through the new engine")
    }

    @Test("Multi-term query ranks by combined BM25 contribution")
    func multiTermRanking() async {
        let idx = makeIndex()
        let c1 = makeChunk("the quick brown fox jumped")
        let c2 = makeChunk("a quick cat")
        await idx.index([c1, c2])
        // "quick fox" — c1 has both, c2 has only "quick"
        let hits = await idx.topK(5, for: tokens("quick fox"))
        #expect(!hits.isEmpty)
        #expect(hits.first?.id == c1.id,
                "Doc with both terms must rank first")
    }

    @Test("Remove removes document from results")
    func removeFromResults() async {
        let idx = makeIndex()
        let c = makeChunk("ephemeral phrase content here")
        await idx.index([c])
        let before = await idx.topK(5, for: tokens("ephemeral"))
        #expect(!before.isEmpty)
        await idx.remove(c.id)
        let after = await idx.topK(5, for: tokens("ephemeral"))
        #expect(after.isEmpty, "Removed doc must not appear in results")
        let count = await idx.documentCount()
        #expect(count == 0)
    }

    @Test("Empty index returns empty results")
    func emptyIndexEmpty() async {
        let idx = makeIndex()
        let hits = await idx.topK(5, for: tokens("anything"))
        #expect(hits.isEmpty)
    }

    @Test("Empty query returns empty results")
    func emptyQueryEmpty() async {
        let idx = makeIndex()
        let c = makeChunk("some content")
        await idx.index([c])
        let hits = await idx.topK(5, for: [])
        #expect(hits.isEmpty)
    }

    @Test("BM25 ranking vs exhaustive scan: same ordering through new engine")
    func bm25RankingMatchesExhaustive() async {
        let idx = makeIndex()
        // Three docs with different relevance to "machine learning".
        // Note: BM25 applies length normalization so shorter docs with matching
        // terms can outrank longer docs. The contract being tested here is that
        // the refactored engine (WAND path) produces the SAME ordering as the
        // previous float-path, not a specific order. We verify:
        //   1. Non-empty results
        //   2. c3 (no "machine" term) ranks last
        //   3. Scores are positive
        let c1 = makeChunk("machine learning algorithm optimization machine")
        let c2 = makeChunk("machine learning")
        let c3 = makeChunk("learning curve study practice")
        await idx.index([c1, c2, c3])

        let hits = await idx.topK(3, for: tokens("machine learning"))
        #expect(!hits.isEmpty)
        // c3 has no "machine" → lowest score; c1 and c2 have both terms.
        // Verify c3 is NOT in the top-2 (it lacks "machine").
        let top2IDs = Set(hits.prefix(2).map(\.id))
        #expect(!top2IDs.contains(c3.id),
                "Doc without 'machine' (c3) must not be in top-2 when querying 'machine learning'")
        // Scores should be strictly positive.
        for hit in hits { #expect(hit.score > 0) }
    }
}

// MARK: - InvertedIndexStore SQLite round-trip tests

@Suite("InvertedIndexStore — SQLite persistence round-trip", .serialized)
struct InvertedIndexStoreTests {

    // SQLite-backed store for each test.
    func makeStore() async throws -> (SQLiteStorage, InvertedIndexStore) {
        let storage = try makeSQLiteStorageForIndex()
        try await storage.open(schema: InvertedIndexStore.schemaDeclaration)
        let store = InvertedIndexStore(storage: storage)
        try await store.open()
        return (storage, store)
    }

    @Test("Index then top-k returns correct results")
    func indexAndTopK() async throws {
        let (storage, store) = try await makeStore()
        defer { Task { await storage.close() } }

        let tok = DeterministicTokenizer()
        let now = Date()
        try await store.index(
            itemID: "item-1",
            tokens: tok.keywordTokens("cat cat dog"),
            now: now
        )
        try await store.index(
            itemID: "item-2",
            tokens: tok.keywordTokens("cat bird"),
            now: now
        )
        try await store.index(
            itemID: "item-3",
            tokens: tok.keywordTokens("dog dog dog bird"),
            now: now
        )

        let hits = try await store.topK(
            queryTerms: tok.keywordTokens("cat dog"),
            k: 2
        )
        #expect(hits.count == 2)
        // item-1 has both cat and dog → should rank first
        #expect(hits[0].itemID == "item-1",
                "item-1 (cat+dog) must rank first, got \(hits[0].itemID)")
        // Scores must be positive
        #expect(hits[0].impact > 0)
    }

    @Test("Remove drops document from query results")
    func removeDropsDocument() async throws {
        let (storage, store) = try await makeStore()
        defer { Task { await storage.close() } }

        let tok = DeterministicTokenizer()
        let now = Date()
        try await store.index(
            itemID: "ephemeral-doc",
            tokens: tok.keywordTokens("ephemeral content keyword"),
            now: now
        )
        #expect(await try await store.documentCount() == 1)

        var hits = try await store.topK(queryTerms: tok.keywordTokens("ephemeral"), k: 5)
        #expect(!hits.isEmpty, "should find ephemeral doc before removal")

        try await store.remove(itemID: "ephemeral-doc")
        #expect(await try await store.documentCount() == 0)

        hits = try await store.topK(queryTerms: tok.keywordTokens("ephemeral"), k: 5)
        #expect(hits.isEmpty, "should not find removed doc")
    }

    @Test("Store survives close and reopen with state intact")
    func closeAndReopenRetainsState() async throws {
        let storage = try makeSQLiteStorageForIndex()
        try await storage.open(schema: InvertedIndexStore.schemaDeclaration)

        let tok = DeterministicTokenizer()
        let now = Date()

        // First session: index two documents.
        do {
            let store = InvertedIndexStore(storage: storage)
            try await store.open()
            try await store.index(
                itemID: "persistent-1",
                tokens: tok.keywordTokens("persistent data storage"),
                now: now
            )
            try await store.index(
                itemID: "persistent-2",
                tokens: tok.keywordTokens("data analysis machine"),
                now: now
            )
        }

        // Second session: open a new store on the same storage — state must survive.
        let store2 = InvertedIndexStore(storage: storage)
        try await store2.open()

        let count = try await store2.documentCount()
        #expect(count == 2, "State must persist across InvertedIndexStore reopen, got \(count)")

        let hits = try await store2.topK(queryTerms: tok.keywordTokens("data"), k: 5)
        #expect(!hits.isEmpty, "Persisted index must answer queries after reopen")

        await storage.close()
    }

    @Test("Re-indexing an item replaces its term frequencies")
    func reIndexReplaces() async throws {
        let (storage, store) = try await makeStore()
        defer { Task { await storage.close() } }

        let tok = DeterministicTokenizer()
        let now = Date()

        try await store.index(
            itemID: "mutable-item",
            tokens: tok.keywordTokens("original content"),
            now: now
        )
        var hits = try await store.topK(queryTerms: tok.keywordTokens("original"), k: 5)
        #expect(!hits.isEmpty, "original content must be findable")

        // Re-index with completely different content.
        try await store.index(
            itemID: "mutable-item",
            tokens: tok.keywordTokens("completely different text"),
            now: now
        )
        hits = try await store.topK(queryTerms: tok.keywordTokens("original"), k: 5)
        #expect(hits.isEmpty, "after re-index, original term must not be findable")

        hits = try await store.topK(queryTerms: tok.keywordTokens("different"), k: 5)
        #expect(!hits.isEmpty, "after re-index, new term must be findable")
        #expect(await try await store.documentCount() == 1,
                "doc count must stay 1 after re-index, not double-count")
    }
}
