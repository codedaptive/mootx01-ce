// FusionTests.swift
//
// Unit tests for Fusion (Engine/Fusion.swift).
//
// Test coverage:
//   1. Single-lane: score order preserved in output.
//   2. Two-lane fusion: item in both lanes ranks ahead of single-lane items.
//   3. Tie-break: equal fused scores → itemID ascending.
//   4. Per-lane scores propagated to FusedHit.perLane.
//   5. Empty lanes return empty result.
//   6. Zero-weight lane adds no fused score.
//   7. rrfK parameter: smaller rrfK amplifies rank-1 advantage.
//   8. N-lane arbitrary fusion: three lanes, arbitrary weights.
//   9. HybridRecall formula conformance: refactored path reproduces the
//      documented RRF formula (vector+BM25, weight=0.6/0.4, rrfK=60) —
//      regression pin.
//  10. SQLite-backed HybridRecall integration: end-to-end over real SQLite
//      storage, verifying ranking behaviour and conformance to the
//      refactored path.
//
// SQLite-backed storage is used for any test that exercises persistence
// (BundleStore, VectorStore), per the mission constraint "SQLite-backed
// where persistence is involved (NOT InMemory)."

import Testing
import Foundation
import SubstrateTypes
@testable import CorpusKit
import VectorKit
import PersistenceKitSQLite
import PersistenceKit
import EngramLib
import IntellectusLib

@Suite("Fusion")
struct FusionTests {

    // ── 1. Single-lane: score order preserved ──────────────────────────

    @Test func singleLaneScoreOrderPreserved() {
        // One lane with three items sorted score DESC.
        // Fusion should preserve rank order: rank-1 item gets highest fused score.
        let hits = Fusion.fuse(
            scoredLists: [
                .sparse: [
                    (itemID: "item-a", score: 3.0),
                    (itemID: "item-b", score: 2.0),
                    (itemID: "item-c", score: 1.0)
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 60
        )
        #expect(hits.count == 3)
        #expect(hits[0].itemID == "item-a")
        #expect(hits[1].itemID == "item-b")
        #expect(hits[2].itemID == "item-c")
        // Scores should be strictly decreasing (rank-1 > rank-2 > rank-3).
        #expect(hits[0].fusedScore > hits[1].fusedScore)
        #expect(hits[1].fusedScore > hits[2].fusedScore)
    }

    // ── 2. Two-lane: item in both lanes accumulates and ranks first ────

    @Test func twoLaneFusionMergesHits() {
        // item-c appears in both lanes at rank 2 each.
        // item-a is rank 1 in BinaryDense only.
        // item-b is rank 1 in Sparse only.
        // item-c should accumulate from both → highest fused score.
        //
        // Scores (weight=0.6 dense, 0.4 sparse, rrfK=60):
        //   item-a: 0.6/61 ≈ 0.009836
        //   item-b: 0.4/61 ≈ 0.006557
        //   item-c: 0.6/62 + 0.4/62 = 1.0/62 ≈ 0.016129
        let hits = Fusion.fuse(
            scoredLists: [
                .binaryDense: [
                    (itemID: "item-a", score: 10.0),
                    (itemID: "item-c", score: 5.0)
                ],
                .sparse: [
                    (itemID: "item-b", score: 8.0),
                    (itemID: "item-c", score: 4.0)
                ]
            ],
            weights: [.binaryDense: 0.6, .sparse: 0.4],
            rrfK: 60
        )
        #expect(hits.count == 3)
        #expect(hits[0].itemID == "item-c", "item-c in both lanes should rank first")
        // item-a scores more than item-b because vector weight (0.6) > keyword weight (0.4).
        #expect(hits[1].itemID == "item-a")
        #expect(hits[2].itemID == "item-b")
    }

    // ── 3. Tie-break: equal fused scores → itemID ASC ─────────────────

    @Test func tieBrokenByItemIDAscending() {
        // Force equal fused scores by assigning the same rank to two items
        // via the rank-list overload.
        let hits = Fusion.fuse(
            rankedLists: [
                .sparse: [
                    (itemID: "zzz-item", rank: 1),
                    (itemID: "aaa-item", rank: 1)
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 60
        )
        #expect(hits.count == 2)
        // Both have weight/61 fused score; tie-break = itemID ASC.
        #expect(hits[0].itemID == "aaa-item")
        #expect(hits[1].itemID == "zzz-item")
    }

    // ── 4. Per-lane scores propagated ─────────────────────────────────

    @Test func perLaneScoresPropagated() {
        let hits = Fusion.fuse(
            scoredLists: [
                .binaryDense: [(itemID: "item-x", score: 7.0)],
                .sparse:      [(itemID: "item-x", score: 3.5)]
            ],
            weights: [.binaryDense: 0.6, .sparse: 0.4],
            rrfK: 60
        )
        #expect(hits.count == 1)
        let h = hits[0]
        #expect(h.itemID == "item-x")
        let denseScore = h.perLane[.binaryDense]
        let sparseScore = h.perLane[.sparse]
        #expect(denseScore != nil)
        #expect(sparseScore != nil)
        #expect(abs((denseScore ?? 0) - 7.0) < 1e-5, "binary dense raw score")
        #expect(abs((sparseScore ?? 0) - 3.5) < 1e-5, "sparse raw score")
    }

    // ── 5. Empty lanes return empty result ────────────────────────────

    @Test func emptyLanesReturnEmpty() {
        let hits = Fusion.fuse(
            rankedLists: [:],
            weights: [:],
            rrfK: 60
        )
        #expect(hits.isEmpty)
    }

    // ── 6. Zero-weight lane ───────────────────────────────────────────

    @Test func zeroWeightLaneContributesNoScore() {
        let hits = Fusion.fuse(
            rankedLists: [
                .sparse: [(itemID: "item-z", rank: 1)]
            ],
            weights: [.sparse: 0.0],
            rrfK: 60
        )
        #expect(hits.count == 1)
        // weight * 1/(60+1) = 0 → fused score is 0.
        #expect(hits[0].fusedScore == 0.0)
    }

    // ── 7. rrfK parameter affects rank-1 advantage ────────────────────

    @Test func rrfKParameterFlowsThrough() {
        // Smaller rrfK amplifies rank-1 advantage: score_rank1/score_rank2
        // should be larger for small rrfK.
        let hitsLargeK = Fusion.fuse(
            scoredLists: [
                .sparse: [
                    (itemID: "a", score: 2.0),
                    (itemID: "b", score: 1.0)
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 60
        )
        let hitsSmallK = Fusion.fuse(
            scoredLists: [
                .sparse: [
                    (itemID: "a", score: 2.0),
                    (itemID: "b", score: 1.0)
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 0.01
        )
        // Item "a" (rank 1) should beat item "b" (rank 2) in both cases.
        #expect(hitsLargeK[0].itemID == "a")
        #expect(hitsSmallK[0].itemID == "a")
        // With small rrfK the ratio should be larger.
        let ratioLarge = hitsLargeK[0].fusedScore / hitsLargeK[1].fusedScore
        let ratioSmall = hitsSmallK[0].fusedScore / hitsSmallK[1].fusedScore
        #expect(ratioSmall > ratioLarge, "smaller rrfK amplifies rank-1 advantage")
    }

    // ── 8. N-lane arbitrary fusion ────────────────────────────────────

    @Test func nLaneArbitraryFusion() {
        // Three lanes with equal weights of 1.0.
        // item-x is rank 1 in all three → dominates.
        // item-y appears in binaryDense (rank 2) and lateInteraction (rank 2).
        // item-z appears in sparse (rank 2) only.
        // Distinct items: item-x, item-y, item-z → 3 results.
        let hits = Fusion.fuse(
            scoredLists: [
                .binaryDense:    [
                    (itemID: "item-x", score: 5.0),
                    (itemID: "item-y", score: 3.0)
                ],
                .sparse: [
                    (itemID: "item-x", score: 4.0),
                    (itemID: "item-z", score: 2.0)
                ],
                .lateInteraction: [
                    (itemID: "item-x", score: 6.0),
                    (itemID: "item-y", score: 2.5)
                ]
            ],
            weights: [.binaryDense: 1.0, .sparse: 1.0, .lateInteraction: 1.0],
            rrfK: 60
        )
        #expect(hits.count == 3)
        // item-x is rank 1 in all three lanes → accumulates 3 * 1/(61) → highest.
        #expect(hits[0].itemID == "item-x")
        // All three per-lane raw scores should be in FusedHit.perLane for item-x.
        let denseScore = hits[0].perLane[.binaryDense]
        let sparseScore = hits[0].perLane[.sparse]
        let lateScore = hits[0].perLane[.lateInteraction]
        #expect(denseScore != nil)
        #expect(sparseScore != nil)
        #expect(lateScore != nil)
        // item-y appears in two lanes at rank 2 each:
        // score = 1/62 + 1/62 = 2/62 ≈ 0.0323
        // item-z appears in one lane at rank 2:
        // score = 1/62 ≈ 0.0161
        // item-y should beat item-z.
        let itemY = hits.first { $0.itemID == "item-y" }
        let itemZ = hits.first { $0.itemID == "item-z" }
        #expect(itemY != nil)
        #expect(itemZ != nil)
        #expect((itemY?.fusedScore ?? 0) > (itemZ?.fusedScore ?? 0))
    }

    // ── 9. HybridRecall conformance (regression pin) ──────────────────
    //
    // This test pins the RRF formula output for the standard two-lane
    // HybridRecall configuration (vectorWeight=0.6, keywordWeight=0.4,
    // rrfK=60). It verifies the refactored path through Fusion produces
    // the same ordering and scores as the documented formula applied
    // directly, for a fixed synthetic corpus.
    //
    // The corpus: three items with known Hamming distances and BM25 ranks.
    //   item-A: vector rank 1, keyword rank 2 → fused = 0.6/61 + 0.4/62
    //   item-B: vector rank 2, keyword rank 1 → fused = 0.6/62 + 0.4/61
    //   item-C: vector rank 3 only            → fused = 0.6/63
    //
    // Expected order: item-A (≈0.0162) > item-B (≈0.0162) with tie broken
    // by itemID ASC when scores are equal, > item-C (≈0.0095).

    @Test func hybridRecallTwoLaneFormulaConformance() {
        // Compute expected scores directly from the RRF formula.
        let rrfK: Float = 60
        let vw: Float   = 0.6
        let kw: Float   = 0.4

        let scoreA = vw / (rrfK + 1) + kw / (rrfK + 2)  // rank 1 vector, rank 2 keyword
        let scoreB = vw / (rrfK + 2) + kw / (rrfK + 1)  // rank 2 vector, rank 1 keyword
        let scoreC = vw / (rrfK + 3)                      // rank 3 vector only

        // Use Fusion directly with the same inputs HybridRecall would produce.
        let hits = Fusion.fuse(
            rankedLists: [
                .binaryDense: [
                    (itemID: "item-A", rank: 1),
                    (itemID: "item-B", rank: 2),
                    (itemID: "item-C", rank: 3)
                ],
                .sparse: [
                    (itemID: "item-B", rank: 1),
                    (itemID: "item-A", rank: 2)
                ]
            ],
            laneScores: [
                .binaryDense: ["item-A": 0, "item-B": 1, "item-C": 3],
                .sparse: ["item-B": 2.5, "item-A": 1.5]
            ],
            weights: [.binaryDense: vw, .sparse: kw],
            rrfK: rrfK
        )

        #expect(hits.count == 3)

        // Verify computed scores match the formula.
        let eps: Float = 1e-5
        let hitA = hits.first { $0.itemID == "item-A" }
        let hitB = hits.first { $0.itemID == "item-B" }
        let hitC = hits.first { $0.itemID == "item-C" }

        #expect(hitA != nil)
        #expect(hitB != nil)
        #expect(hitC != nil)
        #expect(abs((hitA?.fusedScore ?? 0) - scoreA) < eps, "item-A fused score matches formula")
        #expect(abs((hitB?.fusedScore ?? 0) - scoreB) < eps, "item-B fused score matches formula")
        #expect(abs((hitC?.fusedScore ?? 0) - scoreC) < eps, "item-C fused score matches formula")

        // Note: scoreA and scoreB are equal when vw=0.6, kw=0.4, rrfK=60.
        // (0.6/61 + 0.4/62) vs (0.6/62 + 0.4/61)
        // = (0.6*62 + 0.4*61) / (61*62)  vs  (0.6*61 + 0.4*62) / (61*62)
        // numerators: 37.2+24.4=61.6 vs 36.6+24.8=61.4 → NOT equal; A wins by a small margin.
        // So the order is A > B > C.
        #expect(hits[0].itemID == "item-A", "item-A has highest fused score")
        #expect(hits[1].itemID == "item-B")
        #expect(hits[2].itemID == "item-C")
    }

    // ── 10. SQLite-backed HybridRecall integration (conformance) ──────
    //
    // Runs HybridRecall.recall end-to-end over SQLite-backed stores and
    // verifies:
    //   a) The top-ranked item is the one that scores best on BOTH vector
    //      proximity AND keyword match (alpha document + probe=0 engram).
    //   b) Results are ordered score DESC.
    //   c) vectorScore is non-nil for items that contributed a vector hit.
    //
    // SQLite-backed per mission constraint: "SQLite-backed where
    // persistence is involved (NOT InMemory)."
    //
    // GlobalTestLock: HybridRecall.recall emits metrics; the lock prevents
    // concurrent telemetry tests from seeing spurious emissions in their
    // capturing sinks (same pattern as BundleStoreTests and CorpusTests).

    @Test func hybridRecallSQLiteBackedConformance() async throws {
        try await GlobalTestLock.shared.withLock {
        Intellectus.setEnabled(false)

        let vectorStorage = try makeScratchStorage()
        let bundleStorage = try makeScratchStorage()

        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        try await bundleStorage.open(schema: BundleStore.schemaDeclaration)

        let vectorStore = VectorStore(storage: vectorStorage)
        let bundleStore = BundleStore(storage: bundleStorage)

        // Fixed reference date; passed as filedAt so Date() is not called inside engines.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Build a deterministic corpus of three chunks.
        let texts = ["alpha document", "beta document", "gamma document"]
        var chunks: [Chunk] = []
        for (i, text) in texts.enumerated() {
            chunks.append(Chunk(
                sourceID: "src-1",
                startOffset: i * 100,
                length: text.count,
                text: text,
                hlc: HLC(physicalTime: Int64(i), logicalCount: 0, nodeID: 1)
            ))
        }
        try await bundleStore.insert(chunks)

        // Index BM25 over the chunks.
        let tokenizer = CorpusDefaultTokenizer()
        let bm25 = BM25Index(tokenizer: tokenizer)
        await bm25.index(chunks)

        // Seed VectorStore with Engrams: chunk 0 closest to probe, chunk 2 farthest.
        // Probe is all-zeros; distances are popcount(engram) = 1, 2, 3.
        let engrams: [Engram] = [
            Engram(block0: 0x1, block1: 0, block2: 0, block3: 0),
            Engram(block0: 0x3, block1: 0, block2: 0, block3: 0),
            Engram(block0: 0x7, block1: 0, block2: 0, block3: 0)
        ]
        for (chunk, eng) in zip(chunks, engrams) {
            try await vectorStore.addVector(
                itemID: chunk.id.uuidString,
                engram: eng,
                modelID: "test-model",
                modelVersion: "1.0",
                filedAt: now
            )
        }

        let probe = Engram(block0: 0, block1: 0, block2: 0, block3: 0)
        let results = try await HybridRecall.recall(
            probe: probe,
            query: "alpha",
            modelID: "test-model",
            limit: 3,
            vectorStore: vectorStore,
            bm25: bm25,
            bundleStore: bundleStore
        )

        // Three chunks indexed: expect three results.
        #expect(results.count == 3)
        // "alpha document" ranks first: it has the best vector proximity
        // (Hamming 1 vs probe) AND is the keyword hit for "alpha".
        #expect(results[0].chunk.text == "alpha document")
        // Results are score descending.
        #expect(results[0].score >= results[1].score)
        #expect(results[1].score >= results[2].score)
        // The top result should have a non-nil vectorScore (it contributed
        // a vector hit with distance 1).
        #expect(results[0].vectorScore != nil)
        } // end GlobalTestLock.withLock
    }

    // ── 11. W2: duplicate itemID in a lane is deduped (best-rank wins) ──────────
    //
    // A lane list containing the same itemID twice must produce the same
    // fused score as a deduplicated list containing it once. The second
    // occurrence must NOT double-count the RRF contribution.

    @Test func duplicateItemInLaneDeduplicatesToFirstOccurrence() {
        // Lane with item-x appearing twice: rank 1 and rank 2.
        // The deduped version has item-x at rank 1 only.
        let withDuplicate = Fusion.fuse(
            rankedLists: [
                .sparse: [
                    (itemID: "item-x", rank: 1),
                    (itemID: "item-x", rank: 2)   // duplicate; must be ignored
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 60
        )
        let withoutDuplicate = Fusion.fuse(
            rankedLists: [
                .sparse: [
                    (itemID: "item-x", rank: 1)
                ]
            ],
            weights: [.sparse: 1.0],
            rrfK: 60
        )

        #expect(withDuplicate.count == 1, "item-x deduped to one result")
        #expect(withoutDuplicate.count == 1)

        let scoreWithDup    = withDuplicate[0].fusedScore
        let scoreWithoutDup = withoutDuplicate[0].fusedScore
        let eps: Float = 1e-6
        // Scores must be identical: the duplicate contributes nothing extra.
        #expect(abs(scoreWithDup - scoreWithoutDup) < eps,
            "fused score with duplicate must equal score without duplicate")
    }

    // ── 12. W3: distance-0 vectorScore is non-nil and maximum ──────────────────
    //
    // When the probe Engram is identical to a stored engram (Hamming distance 0),
    // the raw vector lane score is 0.0 (lowest distance = best match). The
    // HybridRecall.recall path must expose vectorScore = non-nil for that hit.
    // Previously, the nil-for-zero convention incorrectly mapped distance-0 to nil.

    @Test func distanceZeroProbducesNonNilVectorScore() async throws {
        try await GlobalTestLock.shared.withLock {
        Intellectus.setEnabled(false)

        let vectorStorage = try makeScratchStorage()
        let bundleStorage = try makeScratchStorage()

        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        try await bundleStorage.open(schema: BundleStore.schemaDeclaration)

        let vectorStore = VectorStore(storage: vectorStorage)
        let bundleStore = BundleStore(storage: bundleStorage)

        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        // Build a single chunk.
        let chunk = Chunk(
            sourceID: "src-distance0",
            startOffset: 0,
            length: 14,
            text: "distance zero",
            hlc: HLC(physicalTime: 0, logicalCount: 0, nodeID: 1)
        )
        try await bundleStore.insert([chunk])

        let bm25 = BM25Index(tokenizer: CorpusDefaultTokenizer())
        await bm25.index([chunk])

        // Store the engram and use the IDENTICAL engram as the probe.
        // Hamming distance = 0 → raw vectorScore = 0.0 (minimum distance).
        let storedEngram = Engram(block0: 0xCAFE_BABE, block1: 0, block2: 0, block3: 0)
        try await vectorStore.addVector(
            itemID: chunk.id.uuidString,
            engram: storedEngram,
            modelID: "test-model",
            modelVersion: "1.0",
            filedAt: now
        )

        let probe = storedEngram   // identical probe → distance 0

        let results = try await HybridRecall.recall(
            probe: probe,
            query: "distance zero",
            modelID: "test-model",
            limit: 5,
            vectorStore: vectorStore,
            bm25: bm25,
            bundleStore: bundleStore
        )

        #expect(results.count == 1, "one chunk in corpus, one result expected")
        let top = results[0]
        // vectorScore must be non-nil: the probe matched this item via the
        // vector lane (distance 0 is the best possible match, not a miss).
        #expect(top.vectorScore != nil,
            "distance-0 match must produce non-nil vectorScore, got nil")
        // The raw score for distance 0 is 0.0; confirm it's exactly that.
        if let vs = top.vectorScore {
            #expect(abs(vs) < 1e-6,
                "distance-0 raw vectorScore must be 0.0, got \(vs)")
        }
        } // end GlobalTestLock.withLock
    }
}
