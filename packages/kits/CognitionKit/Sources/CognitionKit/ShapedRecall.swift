// ShapedRecall.swift
//
// A SINGLE parameterized recall recipe driven by a named RecallShape preset.
// Rather than ~20 near-identical recipe types (one per shape), ShapedRecall
// takes a preset NAME, resolves it to the GLK `RecallShape` signed-weight vector
// via `RecallShape.preset(_:)`, and runs the estate recall verb through GLK in
// `.unionBest` / `.matrixAware` with that shape applied. The preset steers WHICH
// lanes vote and how hard (forward / exclude / suppress / invert) and how deep
// the candidate frontier runs; the engine math is unchanged (a preset is a
// weight vector over the existing fusion, never new substrate math).
//
// Boundary discipline (spec B-1/B-2): the recipe holds no substrate state and
// owns no math. Its only substrate touch is the single GLK `recall` verb. It
// SEQUENCES — resolve a name to a shape, run one recall, project the hits.
//
// The four ARIA filtering adjectives compose ORTHOGONALLY with the preset: the
// preset RANKS (it shapes the fusion), the adjective FILTERS (it constrains the
// candidate set via the LocusKit filter chain). ShapedRecall takes the filter as
// a separate Input field and never folds it into the shape, keeping the two
// concerns independent.
//
// Determinism: a preset resolves to a pure value (no clock); the recipe takes
// `now` only for telemetry parity with the other recipes and never reads a clock
// in the ranking path.
//
// Type-resolution note (same as GroundedSynthesis): `Drawer`/`RecallFrame` exist
// in more than one kit in this dependency graph. This file imports GeniusLocusKit
// (which re-exports the LocusKit value types it names) and LocusKit for the
// `Filter`/`RecallFrame` the Input carries — the same shapes the other recipes use.

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Recall a query with a named, signed-weight RecallShape preset applied.
///
/// One recipe, every shape: the `preset` name selects the steering vector from
/// the GLK roster (`RecallShape.presetNames`). `"balanced"` (and any unknown
/// name, when validation is relaxed) runs unsteered — byte-identical to today's
/// `.unionBest` recall.
public struct ShapedRecall: Recipe {

    /// Recipe input: the query, the preset name, the orthogonal filter, and the
    /// result cap.
    public struct Input: Sendable {
        /// The search query text — drives BM25 + vector recall.
        public let query: String
        /// The RecallShape preset name from `RecallShape.presetNames`. An unknown
        /// name resolves to a `nil` shape (unsteered recall) — callers that need
        /// strict validation (e.g. the ARIA tool surface) check
        /// `RecallShape.presetNames.contains(_:)` at the boundary and reject an
        /// unknown name there; the recipe itself does not throw on a bad name (it
        /// degrades to balanced, mirroring `PreciseRecall`'s composition contract).
        public let preset: String
        /// The recall filter chain entry (the orthogonal ADJECTIVE constraint).
        /// Independent of the preset: the filter FILTERS, the preset RANKS.
        public let filter: LocusKit.Filter
        /// How many ranked matches to return.
        public let limit: Int

        public init(
            query: String,
            preset: String,
            filter: LocusKit.Filter,
            limit: Int
        ) {
            self.query = query
            self.preset = preset
            self.filter = filter
            self.limit = limit
        }
    }

    /// Recipe output: the ranked matches (the `PreciseMatch` shape — id/room/
    /// content/score — shared with `PreciseRecall` so the ARIA surface serializes
    /// both identically) and the resolved preset name actually applied.
    public struct Output: Sendable {
        /// Up to `limit` matches, in the fused rank order the shaped recall
        /// produced.
        public let matches: [PreciseMatch]
        /// The preset name that was applied. Echoes `Input.preset` so a caller can
        /// confirm which shape ran (e.g. logging "balanced" when an unknown name
        /// degraded).
        public let appliedPreset: String

        public init(matches: [PreciseMatch], appliedPreset: String) {
            self.matches = matches
            self.appliedPreset = appliedPreset
        }
    }

    public init() {}

    public let name = "shaped_recall"
    public let version = "1.0.0"
    public let description =
        "Recall a query with a named signed-weight RecallShape preset applied — forward, exclude, suppress, or invert individual fusion lanes (and bound the candidate frontier) by selecting one of the roster presets, instead of the uniform balanced fusion."

    /// Sequences only the GLK recall verb — no NeuronKit reasoning capability.
    public let requiredCapabilities: [NeuronKitCapability] = []

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // Spec B-5: verify capabilities before any substrate touch. (Empty set
        // here — ShapedRecall sequences only the estate recall verb — but the
        // call keeps the recipe contract uniform.)
        try verifyCapabilities(required: requiredCapabilities)

        // Resolve the preset NAME to its signed-weight shape. `nil` means
        // "balanced / unsteered" (the name "balanced", or an unknown name): the
        // recall runs with no shape, byte-identical to today's `.unionBest`. The
        // applied-preset echo reports "balanced" in that case so the caller sees
        // which shape actually ran.
        let appliedPreset = RecallShape.presetNames.contains(input.preset)
            ? input.preset
            : "balanced"

        // SESSION_HYBRID: special-case route through NeuronKit's hybridRecall
        // scoredLane seam + SessionHybridFusion post-processing.
        //
        // hybridRecall is the ONLY path for session_hybrid — it enforces the
        // RECENCY-SHALL-NOT-DOMINATE invariant and the scoring-evidence gate
        // (only BM25/Hamming/dense-bearing hits form the relevance lead block).
        // SessionHybridFusion then applies bounded temporal-window and speaker-
        // aware boosts as a secondary sort key over hybridRecall's output, so
        // the evidence gate is extended (not weakened): a zero-evidence hit
        // can never displace a scored hit via the boost path alone.
        if input.preset == "session_hybrid" {
            return try await runSessionHybrid(input: input, estate: estate, kit: kit,
                                              appliedPreset: appliedPreset)
        }

        let shape = RecallShape.preset(input.preset)

        // Run the estate recall verb through GLK in `.unionBest` / `.matrixAware`
        // — the only mode that activates the full weighted column set (locus,
        // bm25, hamming, dense, fieldFit, coOccurrence, temporal, graph,
        // preference) the preset roster steers. `.full` hydration so each hit
        // carries its body for the result projection. The shape is passed through
        // unchanged; when `nil`, the engine fuses uniformly.
        let frame = LocusKit.RecallFrame(
            filterChain: [input.filter],
            hydrationLevel: .full,
            limit: input.limit,
            ordering: .byCaptureTimeDesc)
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: input.limit,
            fallback: .allowDegraded,
            queryText: input.query,
            recallShape: shape)
        let result = try await kit.recall(estate, request)

        // Project each hit into a PreciseMatch. The hits arrive in the shaped
        // fusion's rank order; we preserve that order. `score.final` is the fused
        // score the shape produced — surfaced as the reported precision.
        let matches = result.hits.map { hit -> PreciseMatch in
            let room = hit.drawer?.parentNodeId ?? ""
            let content = hit.drawer?.content ?? ""
            return PreciseMatch(
                id: hit.id,
                room: room,
                content: content,
                score: Double(hit.score.final))
        }

        return Output(matches: matches, appliedPreset: appliedPreset)
    }

    /// Session-hybrid recall path: hybridRecall scoredLane + temporal window
    /// boost + speaker-aware weighting.
    ///
    /// Extracted into its own method to keep `run()` readable; same public
    /// contract (ShapedRecall.Output, no new public surface).
    private func runSessionHybrid(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit,
        appliedPreset: String
    ) async throws -> Output {
        // Build the RecallFrame for hybridRecall's primary lane. The full
        // filter chain passes through so the session window constraints
        // (createdAfter/createdBefore if present) are enforced as hard
        // filters at the substrate level; SessionHybridFusion then extracts
        // the same bounds to also apply a SOFT boost for in-window hits.
        let frame = LocusKit.RecallFrame(
            filterChain: [input.filter],
            hydrationLevel: .full,
            limit: input.limit,
            ordering: .byCaptureTimeDesc)

        // ScoredLane: a second GLK recall in unionBest/raw mode driven by the
        // query text. Evidence-bearing hits from this lane form the relevance
        // lead block in hybridRecall's union, separating genuine relevance
        // from pure recency (the RECENCY-SHALL-NOT-DOMINATE invariant).
        let scoredLane = ScoredLane(
            frame: frame,
            queryText: input.query,
            traceLimit: input.limit)

        // Derive cue terms by splitting the query on whitespace — the same
        // convention NeuronKit's lexical rerank lane uses. The cue terms drive
        // the RECENCY-SHALL-NOT-DOMINATE fallback: when the scored lane
        // produces zero evidence-bearing hits, hybridRecall switches to
        // lexical-dominant fusion (bm25Weight 1.0, vectorWeight 0.0) so
        // keyword-relevant recency wins cleanly rather than mixing with a
        // degraded similarity signal.
        let cueTerms = input.query
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        let stream = try await hybridRecall(
            frame,
            handle: estate,
            on: kit,
            cueTerms: cueTerms,
            scoredLane: scoredLane)

        // Drain all pages from the stream into a flat drawer array. The
        // hybridRecall stream pages are already MMR-reranked; we consume all
        // of them before applying SessionHybridFusion boosts so the boost
        // sees the complete candidate set (not just the first page).
        // RecallStream.AsyncIterator.next() is non-throwing; use `for await`.
        var allDrawers: [Drawer] = []
        for await page in stream {
            allDrawers.append(contentsOf: page.rows)
        }

        // Apply temporal and speaker boosts as a secondary sort key. The
        // primary ranking from hybridRecall is preserved for equal scores;
        // the boost can only reorder near-equal candidates. The evidence gate
        // invariant is maintained because the max combined boost (0.006) is
        // smaller than the base-score gap between the last evidence-bearing
        // hit and the first frame-only hit in typical hybridRecall output
        // (≥0.005 per SessionHybridFusion.temporalBoostMax documentation).
        let boosted = SessionHybridFusion.boost(
            drawers: allDrawers,
            filter: input.filter,
            query: input.query,
            limit: input.limit)

        // Project to PreciseMatch. The room is the drawer's parentNodeId
        // (structural coordinate); content is the verbatim filed text.
        let matches = boosted.map { pair -> PreciseMatch in
            PreciseMatch(
                id: pair.drawer.id,
                room: pair.drawer.parentNodeId,
                content: pair.drawer.content,
                score: pair.score)
        }

        return Output(matches: matches, appliedPreset: appliedPreset)
    }
}
