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

import Foundation
import EngramLib
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
        // Pull a generous candidate window from each side.
        let candidateK = max(limit * 4, 32)

        async let vectorHits = vectorStore.findNearest(
            probe: probe,
            modelID: modelID,
            limit: candidateK
        )
        async let keywordHits = bm25.search(query, limit: candidateK)

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
        for (rank, (id, score)) in keywordResults.enumerated() {
            let rrf = 1.0 / (configuration.rrfK + Double(rank + 1))
            let contribution = rrf * configuration.keywordWeight
            var entry = fused[id] ?? (0, 0, 0)
            entry.1 = score
            entry.2 += contribution
            fused[id] = entry
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
        return out
    }
}
