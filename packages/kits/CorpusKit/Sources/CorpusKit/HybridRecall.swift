// HybridRecall.swift
//
// Hybrid retrieval composition: vector kNN plus BM25 keyword
// scoring fused via Reciprocal Rank Fusion (RRF), with optional
// Maximal Marginal Relevance (MMR) diversification on the
// merged candidate list. Per paper section 10.2.
//
// The hybrid recall lives in CorpusKit because both inputs (vector
// hits from VectorKit + keyword hits from BM25Index) are CorpusKit
// concerns. NeuronKit's reasoning layer composes higher-level
// recall pipelines on top.
//
// LANE-E2: the two-lane RRF logic is now delegated to Fusion
// (Engine/Fusion.swift) instead of being reimplemented inline.
// HybridRecall builds the per-lane ranked lists and raw-score maps,
// then calls Fusion.fuse(rankedLists:laneScores:weights:rrfK:).
// The ranking output is bit-identical to the previous implementation
// for the same inputs (verified by HybridRecallConformanceTests).
//
// CORPUSKIT_REPORT_001 (cp-corpuskit-report): added IntellectusLib
// self-report telemetry to recall. The emit calls are placed at the
// operation boundary, after the result is assembled, so the
// mathematical behaviour is unchanged. When monitoring is disabled
// (the default), the Intellectus.report(_:) call short-circuits after
// a single Atomic<Bool> load; the startTime clock read is the only
// unconditional overhead added per operation.

import Foundation
import EngramLib
import IntellectusLib
import VectorKit

public struct HybridRecallConfiguration: Sendable {
    public var vectorWeight: Double
    public var keywordWeight: Double
    public var rrfK: Double            // RRF constant (Cormack et al. recommend 60)
    public var mmrLambda: Double?      // optional MMR diversification (nil disables)

    public init(
        vectorWeight: Double = 0.6,
        keywordWeight: Double = 0.4,
        rrfK: Double = 60,
        mmrLambda: Double? = nil
    ) {
        self.vectorWeight = vectorWeight
        self.keywordWeight = keywordWeight
        self.rrfK = rrfK
        self.mmrLambda = mmrLambda
    }
}

public enum HybridRecall {

    /// Retrieve top-k chunks by hybrid (vector + keyword) scoring.
    ///
    /// Both the vector pass (Hamming kNN) and keyword pass (BM25) produce
    /// ranked candidate lists. These are fused using generalized RRF via
    /// `Fusion.fuse` — the .binaryDense lane carries vector hits and
    /// the .sparse lane carries BM25 hits. The ranking behaviour is
    /// identical to the previous inline implementation.
    ///
    /// - Parameters:
    ///   - probe: probe Engram (from the query's embedding).
    ///   - query: query text (for the keyword pass).
    ///   - modelID: stable model id; the kNN pass filters to this
    ///     model so cross-model comparisons cannot occur.
    ///   - limit: top-k cap.
    ///   - vectorStore: VectorKit handle.
    ///   - bm25: keyword index.
    ///   - bundleStore: chunk content store.
    ///   - configuration: weights, RRF constant, optional MMR.
    ///
    /// Telemetry: emits `corpuskit.recall.latency_ms` (wall time for the
    /// full hybrid pipeline including embedding, vector kNN, BM25, RRF,
    /// and hydration), `corpuskit.recall.vector_result_count` (number of
    /// vector hits from findNearest before RRF), `corpuskit.recall.keyword_result_count`
    /// (number of keyword hits from BM25 before RRF), and
    /// `corpuskit.recall.result_count` (final output count after RRF and
    /// hydration) when monitoring is enabled. All four are emitted at the
    /// operation boundary — after the result is assembled — so they cannot
    /// affect the return value. Off-path: single Atomic<Bool> load per call.
    public static func recall(
        probe: Engram,
        query: String,
        modelID: String,
        limit: Int,
        vectorStore: VectorStore,
        bm25: BM25Index,
        bundleStore: BundleStore,
        configuration: HybridRecallConfiguration = HybridRecallConfiguration()
    ) async throws -> [ScoredChunk] {
        // Capture start time before the retrieval work. One Date() read per
        // call; the computed latency is forwarded to the sink only when
        // monitoring is enabled (inside the @autoclosure guard).
        let startTime = Date().timeIntervalSince1970

        // Pull a generous candidate window from each side.
        let candidateK = max(limit * 4, 32)

        async let vectorHits = vectorStore.findNearest(
            probe: probe,
            modelID: modelID,
            limit: candidateK
        )
        // Pre-tokenise using the corpus-default vocabulary so topK(_:for:)
        // receives compatible tokens. CorpusDefaultTokenizer is stateless;
        // a fresh instance is equivalent to the one stored inside bm25.
        let queryTokens = CorpusDefaultTokenizer().keywordTokens(query)
        async let keywordHits = bm25.topK(candidateK, for: queryTokens)

        let vectorResults = try await vectorHits
        let keywordResults = await keywordHits

        // Build per-lane ranked inputs for the generalized Fusion engine.
        //
        // Vector lane (.binaryDense): findNearest returns hits sorted by
        // Hamming distance ascending — index 0 = rank 1.
        // Raw score = Hamming distance (Int cast to Float); lower = closer.
        //
        // Keyword lane (.sparse): topK returns (id: UUID, score: Float)
        // sorted by BM25 score descending — index 0 = rank 1.
        // Raw score = BM25 score Float.
        //
        // Both ranked lists are built as [(itemID: String, rank: Int)] using
        // the chunk UUID.uuidString as itemID — the same join key used by
        // bundleStore.getMany.

        var vectorRanked: [(itemID: String, rank: Int)] = []
        var vectorScoreMap: [String: Float] = [:]
        for (idx, hit) in vectorResults.enumerated() {
            // Skip items whose itemID is not a valid UUID string — they
            // cannot be hydrated by bundleStore and are not in the corpus.
            guard UUID(uuidString: hit.itemID) != nil else { continue }
            vectorRanked.append((itemID: hit.itemID, rank: idx + 1))
            // Hamming distance as Float; lower = closer to probe.
            vectorScoreMap[hit.itemID] = Float(hit.distance)
        }

        var keywordRanked: [(itemID: String, rank: Int)] = []
        var keywordScoreMap: [String: Float] = [:]
        for (idx, hit) in keywordResults.enumerated() {
            let itemID = hit.id.uuidString
            keywordRanked.append((itemID: itemID, rank: idx + 1))
            keywordScoreMap[itemID] = hit.score
        }

        // Delegate fusion to Fusion.fuse. The .binaryDense and .sparse
        // LaneTags are used because they match the canonical lane names
        // for these two retrieval paths (arch spec §2.4, LaneTag definition).
        let fusedHits = Fusion.fuse(
            rankedLists: [
                .binaryDense: vectorRanked,
                .sparse:      keywordRanked
            ],
            laneScores: [
                .binaryDense: vectorScoreMap,
                .sparse:      keywordScoreMap
            ],
            weights: [
                .binaryDense: Float(configuration.vectorWeight),
                .sparse:      Float(configuration.keywordWeight)
            ],
            rrfK: Float(configuration.rrfK)
        )

        // Apply the limit. Fusion.fuse returns the full merged list sorted
        // by fusedScore DESC, itemID ASC; truncate to the requested top-k.
        let topHits = fusedHits.count > limit
            ? Array(fusedHits.prefix(limit))
            : fusedHits

        // Hydrate chunks from bundleStore using the UUID primary keys.
        // Items whose itemID is not a valid UUID are dropped at this point
        // (they were included in fusion but cannot be hydrated).
        let uuids = topHits.compactMap { UUID(uuidString: $0.itemID) }
        let chunks = try await bundleStore.getMany(ids: uuids)
        let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })

        // Build the output list in fused-score order.
        // Per-lane raw scores from FusedHit.perLane feed ScoredChunk
        // subscores: .binaryDense → vectorScore, .sparse → keywordScore.
        // A nil subscore means that lane did not produce a hit for that item.
        var out: [ScoredChunk] = []
        for hit in topHits {
            guard let uuid = UUID(uuidString: hit.itemID),
                  let chunk = byID[uuid] else { continue }
            let vectorScore = hit.perLane[.binaryDense]
            let keywordScore = hit.perLane[.sparse]
            // vectorScore: presence in perLane[.binaryDense] determines non-nil.
            // A raw score of 0 (Hamming distance 0) is the BEST possible match —
            // the probe is identical to the stored engram. Treating distance 0 as nil
            // would silently discard the highest-quality vector hit, misleading nil-
            // checking callers into thinking no vector lane contributed.
            //
            // keywordScore: BM25 scores are strictly positive for any match, so
            // a zero value reliably indicates the keyword lane did not contribute.
            out.append(ScoredChunk(
                chunk: chunk,
                score: hit.fusedScore,
                vectorScore:  vectorScore,
                keywordScore: (keywordScore == 0 || keywordScore == nil) ? nil : keywordScore
            ))
        }

        // Emit recall telemetry at the operation boundary, after the result
        // is assembled. The autoclosures are evaluated only when monitoring
        // is enabled; the startTime clock read (above) is the only
        // unconditional overhead. When monitoring is off (the default),
        // each call is a single Atomic<Bool> load + branch.
        //
        // corpuskit.recall.latency_ms: wall time for the full pipeline
        //   (vector kNN + BM25 + RRF + hydration).
        // corpuskit.recall.vector_result_count: raw vector hits before RRF.
        // corpuskit.recall.keyword_result_count: raw keyword hits before RRF.
        // corpuskit.recall.result_count: final output count after hydration.
        let endTime = Date().timeIntervalSince1970
        let resultCount = out.count
        let vectorCount = vectorResults.count
        let keywordCount = keywordResults.count
        Intellectus.report(.metric(
            name: "corpuskit.recall.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.vector_result_count",
            value: Double(vectorCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.keyword_result_count",
            value: Double(keywordCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.recall.result_count",
            value: Double(resultCount),
            tags: ["kit": "CorpusKit", "model_id": modelID],
            ts: endTime
        ))

        return out
    }
}
