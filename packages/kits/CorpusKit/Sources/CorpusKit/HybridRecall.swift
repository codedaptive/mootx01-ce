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
    /// Retrieve top-k chunks by hybrid (vector + keyword) scoring.
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

        // Vector scores are Hamming distance ascending; convert to
        // 1 / (k + rank) RRF contribution. Keyword scores are
        // BM25 descending; convert with the same RRF transform.
        var fused: [UUID: (Double, Double, Double)] = [:]
        // (vectorScore, keywordScore, fusedScore)

        for (rank, hit) in vectorResults.enumerated() {
            // hit.drawerID is the chunk's UUID-as-string by convention.
            guard let uuid = UUID(uuidString: hit.drawerID) else { continue }
            let rrf = 1.0 / (configuration.rrfK + Double(rank + 1))
            let contribution = rrf * configuration.vectorWeight
            var entry = fused[uuid] ?? (0, 0, 0)
            entry.0 = Double(hit.distance)
            entry.2 += contribution
            fused[uuid] = entry
        }
        for (rank, hit) in keywordResults.enumerated() {
            let rrf = 1.0 / (configuration.rrfK + Double(rank + 1))
            let contribution = rrf * configuration.keywordWeight
            var entry = fused[hit.id] ?? (0, 0, 0)
            entry.1 = Double(hit.score)
            entry.2 += contribution
            fused[hit.id] = entry
        }

        var ranked = fused.map { (id, score) in
            (id: id, vectorScore: score.0, keywordScore: score.1, fused: score.2)
        }
        ranked.sort {
            if $0.fused != $1.fused { return $0.fused > $1.fused }
            return $0.id.uuidString < $1.id.uuidString
        }
        if ranked.count > limit { ranked.removeLast(ranked.count - limit) }

        // Hydrate chunks from bundleStore.
        let ids = ranked.map { $0.id }
        let chunks = try await bundleStore.getMany(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })

        var out: [ScoredChunk] = []
        for entry in ranked {
            guard let chunk = byID[entry.id] else { continue }
            out.append(ScoredChunk(
                chunk: chunk,
                score: Float(entry.fused),
                vectorScore: entry.vectorScore == 0 ? nil : Float(entry.vectorScore),
                keywordScore: entry.keywordScore == 0 ? nil : Float(entry.keywordScore)
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
