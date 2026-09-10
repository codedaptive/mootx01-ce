// DistilledRecall.swift
//
// Distilled-payload recall recipe.
//
// `moot_recall_distilled` is EXACT-SEARCH GEOMETRY over originals +
// inline distilled-representation hydration of the hits: the same recall
// request `moot_memory_search` runs (unionBest, matrixAware fusion,
// query text), with the hydration selector pinned to `distilled`.
// Ranking is identical to exact search BY CONSTRUCTION; only the
// payloads differ (smaller). Per-hit response metadata carries
// `token_count` (context budgeting). Every row renders inline — there is
// no sweep, no "not yet distilled" state, and no fallback marker.
//
// Each match also carries `originalTokenCount`, the estimator over the
// record's full content. The recipe does not sum the pair: the ARIA v2
// surface applies `DistilledSavings` over the rows it actually emits,
// after its row cap and privacy projection (ARIA_V2_CONTRACT.md,
// "Distilled recall savings").
//
// Layer discipline B-1/B-2: one GLK recall call. Read-only (B-6, I-6).

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML

// MARK: - Output types

/// How well the top result separates from the rest of the ranked list.
///
/// Mirrors AriaMcpKit.DiscriminationLevel case-for-case. Defined locally
/// because AriaMcpKit is downstream of CognitionKit and cannot be
/// imported here. Thresholds: HIGH_MARGIN = 0.25, LOW_MARGIN = 0.05,
/// LOW_SPREAD = 0.15. Computed over the SEARCH scores (the exact-search
/// geometry's ranking signal), not any distillation metadata.
public enum DistilledDiscriminationLevel: Sendable, Equatable {
    /// Fewer than two results — nothing to compare.
    case single
    /// Top result is clearly separated from the second (topGap >= 0.25).
    case high
    /// Partial separation — some evidence of a best hit.
    case medium
    /// Top results within epsilon — effectively unranked.
    case low
}

/// One hit from distilled recall: an ORIGINAL drawer (exact-search
/// geometry), hydrated with its inline distilled representation.
public struct DistilledMatch: Sendable, Equatable, Codable {
    /// SOURCE drawer UUID from the estate (the item itself — there is no
    /// factoid tier; `moot_memory_get` on this id returns the full body).
    public let id: String
    /// The hydrated payload: the inline distilled rendering of the row's
    /// verbatim content, produced at read time by ContextDistillLib.
    public let text: String
    /// Per-hit token estimate for context budgeting. Always present —
    /// every row renders inline, so there is no fallback without a count.
    public let tokenCount: Int64
    /// Estimator over the record's full `content`: the original-body cost
    /// the ARIA surface sums over the rows it emits. Never summed here.
    public let originalTokenCount: Int64
    /// The exact-search fusion score that ranked this hit.
    public let score: Double
    /// The room node id of the source drawer (callers resolve display
    /// names through the node tree exactly as `moot_memory_search` does).
    public let parentNodeId: String

    public init(
        id: String,
        text: String,
        tokenCount: Int64,
        originalTokenCount: Int64,
        score: Double,
        parentNodeId: String
    ) {
        self.id = id
        self.text = text
        self.tokenCount = tokenCount
        self.originalTokenCount = originalTokenCount
        self.score = score
        self.parentNodeId = parentNodeId
    }
}

// MARK: - Recipe

/// Distilled-payload recall: exact-search geometry, inline distilled hydration.
///
/// RecipeCatalog registration is present.
public struct DistilledRecall: Recipe {

    // MARK: Input

    public struct Input: Sendable {
        /// Query text — drives the same BM25 + vector + matrix fusion the
        /// exact-search path runs.
        public let query: String
        /// ARIA adjective filter applied by the recall frame. Normal
        /// recall liveness, trust, and sensitivity defaults are enforced
        /// by the substrate before any payload is returned.
        public let filter: LocusKit.Filter
        /// Maximum hits to return. Default 20.
        public let limit: Int

        public init(
            query: String,
            filter: LocusKit.Filter = .currentlyBelieve,
            limit: Int = 20
        ) {
            self.query = query
            self.filter = filter
            self.limit = limit
        }
    }

    // MARK: Output

    public struct Output: Sendable {
        public let matches: [DistilledMatch]
        public let discrimination: DistilledDiscriminationLevel

        public init(matches: [DistilledMatch], discrimination: DistilledDiscriminationLevel) {
            self.matches = matches
            self.discrimination = discrimination
        }
    }

    // MARK: Recipe identity

    public let name = "distilled_recall"
    public let version = "2.0.0"
    public let description =
        "Distilled recall: exact-search geometry over originals with the "
        + "hydration selector pinned to `distilled` — identical ranking to "
        + "exact search, smaller payloads, per-hit token counts."

    // One recall call; no reasoning capabilities required.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: run()

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // The exact-search request shape (`moot_memory_search`): unionBest
        // mode, matrixAware fusion, full hydration. The selector affects
        // only payloads, never matching or ranking.
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [input.filter],
                hydrationLevel: .full,
                limit: input.limit),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: input.limit,
            fallback: .allowDegraded,
            queryText: input.query,
            // origin: .internal — B-10a: recipe layer is never external;
            // only the ARIA_MCP boundary passes .external.
            origin: .internal,
            // Sub-span scoring is an additive-cost stage this recipe does not
            // request; every caller names the switch (ruling 2026-09-07).
            subSpanScoring: .off
        )
        let result = try await kit.recall(estate, request)

        // Hydrate each hit through the hydration selector pinned to .distilled.
        // Every row renders inline via ContextDistillLib — no stored columns,
        // no sweep dependency, no fallback path. Each match carries the
        // estimator over its distilled text and over its full content; the
        // ARIA surface sums both over the rows it emits.
        var matches: [DistilledMatch] = []
        for hit in result.hits {
            guard let drawer = hit.drawer else { continue }
            let text = HydrationRepresentation.distilled.resolve(for: drawer)
            matches.append(DistilledMatch(
                id: drawer.id,
                text: text,
                tokenCount: GeniusLocusKit.estimatedTokenCount(of: text),
                originalTokenCount: GeniusLocusKit.estimatedTokenCount(of: drawer.content),
                score: Double(hit.score.final),
                parentNodeId: drawer.parentNodeId))
        }

        // Discrimination over the exact-search scores.
        return Output(
            matches: matches,
            discrimination: classifyDistilledDiscrimination(matches.map { $0.score }))
    }
}

// MARK: - Discrimination classifier

/// Classify how well the search scores separate the top match from the rest.
///
/// Thresholds mirror AriaMcpKit.RecallDiscrimination:
///   HIGH_MARGIN = 0.25 — topGap at which rank-1 is clearly the best match.
///   LOW_MARGIN  = 0.05 — topGap below which rank-1 is indistinguishable from rank-2.
///   LOW_SPREAD  = 0.15 — spread below which the entire list is effectively flat.
///   EPS         = 1e-9 — prevents division by zero on all-zero score vectors.
private func classifyDistilledDiscrimination(_ scores: [Double]) -> DistilledDiscriminationLevel {
    guard scores.count >= 2 else { return .single }
    let s0 = scores[0]
    let s1 = scores[1]
    let sLast = scores[scores.count - 1]
    let denom = max(abs(s0), 1e-9)
    let topGap = (s0 - s1) / denom
    let spread = (s0 - sLast) / denom
    if topGap >= 0.25 { return .high }
    if topGap < 0.05 && spread < 0.15 { return .low }
    return .medium
}
