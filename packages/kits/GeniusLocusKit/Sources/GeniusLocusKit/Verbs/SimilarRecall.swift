// SimilarRecall.swift
//
// The paraphrase door: nearest drawers by whole-record LSA vector. The corpus
// engine's DEFAULT float slot is the whole-record dense lane, so this verb
// probes `floatNearest` directly, keeps the lane's nearest-first order,
// hydrates the drawers through the estate's frame filter and surfaces them as
// `RecallHit`s whose `score.final` is the raw cosine similarity. No fusion,
// no rerank: the caller asked for "what reads like this", and that is the
// lane's own answer.

import Foundation
import LocusKit

public extension GeniusLocusKit {

    /// Nearest drawers by whole-record LSA vector for a free-text question: the
    /// paraphrase door. Lane order preserved; drawers are hydrated and filtered by `filter`.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - query: free-text question, embedded by the corpus engine's default float slot.
    ///   - limit: maximum hits returned; values below 1 probe for a single hit.
    ///   - filter: the LocusKit filter every returned drawer must satisfy.
    /// - Returns: hits nearest-first with `score.final` = cosine similarity in [−1, 1]
    ///   and `score.dense` = its [0, 1] normalisation. Empty when no corpus engine is
    ///   registered, when the dense lane is dark for this query, or when nothing
    ///   passes `filter`.
    func similarRecall(
        _ handle: EstateHandle,
        query: String,
        limit: Int,
        filter: LocusKit.Filter
    ) async throws -> [RecallHit] {
        let estate = try estate(for: handle)
        guard let engine = corpusKits[handle] else { return [] }
        let want = max(limit, 1)
        // Every dark outcome (provider opt-out, no float rows, vocabulary miss,
        // empty query, store error) is a lane with nothing to say, not an error:
        // the paraphrase door simply has no candidates.
        guard case .hits(let pairs) = await engine.floatNearest(query: query, limit: want) else {
            return []
        }
        let orderedIDs = pairs.map(\.itemID)
        // Hydrate through the frame filter: the evaluator applies `filter`, the
        // tombstone exclusion and the default sensitivity ceiling in one pass.
        // `.full` so the returned drawers carry their content for the caller.
        let filtered = try await estate.getDrawers(
            ids: orderedIDs,
            matchingFrame: RecallFrame(filterChain: [filter]),
            hydrationLevel: .full)
        let byID = Dictionary(
            uniqueKeysWithValues: filtered.admissible.map { ($0.id, $0) })
        var hits: [RecallHit] = []
        hits.reserveCapacity(pairs.count)
        for pair in pairs {
            guard let drawer = byID[pair.itemID],
                  // A superseded row's lane entry lingers until the maintenance
                  // sweep; it must never surface as a hit.
                  drawer.state != .superseded,
                  // ≤ .elevated without a grant: the same ceiling vagueRecall applies.
                  drawer.adjectiveSensitivity.isBulkExportable
            else { continue }
            hits.append(RecallHit(
                id: pair.itemID,
                drawer: drawer,
                sources: [.vectorDense],
                score: RecallScoreVector(
                    locus: 0, bm25: 0, vector: 0, fieldFit: 0, coOccurrence: 0,
                    temporal: 0, graph: 0, preference: 0, redundancyPenalty: 0,
                    final: pair.similarity,
                    // Same [0, 1] convention as the fused dense column: (sim + 1) / 2.
                    dense: max(0, min(1, (pair.similarity + 1) / 2))),
                explanation: ["vectorDense"]))
            if hits.count >= want { break }
        }
        return hits
    }
}
