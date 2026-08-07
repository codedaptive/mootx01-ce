// GroundedSynthesis.swift
//
// A conscious recall recipe: take a recall frame, run NeuronKit's
// hybrid recall (RRF + MMR over the GLK recall verb), drain the paged
// result, and synthesize the full recalled set into a single
// `ContextDocument` for foundation-model consumption.
//
// This is the cleanest end-to-end through-line in CognitionKit: it
// proves SubstrateML/GLK → NeuronKit reasoning → CognitionKit recipe
// with nothing faked. It touches no COW branches and needs no
// proposal/confirmation rail — it is pure conscious recall + synthesis.
//
// Boundary discipline (spec B-1/B-2): the recipe holds no substrate
// state. The only substrate read is NeuronKit's `hybridRecall`, which
// itself reads through the single GLK `recall` verb boundary.
// `ContextSynthesizer.synthesize` is read-only (NeuronKit C-9): it
// consults only the rows already materialised in the page.
//
// Type-resolution note: `Drawer`, `RecallStream`, and `RecallFrame`
// each exist in more than one of the kits in this dependency graph
// (LocusKit and its NeuronKit / GeniusLocusKit re-exports), so the bare
// names are ambiguous when LocusKit is imported directly. This file
// imports only GeniusLocusKit + NeuronKit and never spells `Drawer`:
//   - `RecallStream` / `RecallFrameTuning` / `ContextDocument` /
//     `ContextSynthesizer` / `hybridRecall` resolve unambiguously to
//     NeuronKit (LocusKit's same-named types are out of scope here).
//   - `RecallFrame` resolves to GeniusLocusKit's typealias of
//     `LocusKit.RecallFrame` (one declaration in scope). The recipe's
//     `Input.frame` is that type; a caller importing LocusKit may pass a
//     `LocusKit.RecallFrame` — it is the same underlying type.

import Foundation
import GeniusLocusKit
import IntellectusLib
import NeuronKit

/// Recall + ground a query into a synthesized context document.
public struct GroundedSynthesis: Recipe {

    /// Recipe input: the recall frame to ground, plus the hybrid-recall
    /// tuning (RRF/MMR/page-size). Tuning defaults to NeuronKit's spec
    /// defaults (k = 60, λ = 0.7, page 50).
    public struct Input: Sendable {
        /// The estate recall frame (filter chain, ordering, limit).
        public let frame: RecallFrame
        /// Hybrid-recall tuning knobs. Defaults to `.default`.
        public let tuning: RecallFrameTuning
        /// Cue terms for the lexical RRF lane. When non-empty, drawers are
        /// reranked by distinct-cue-term-match count before synthesis,
        /// surfacing the most query-relevant drawers over the most recent.
        /// Default [] = input-order recency lane only (previous behaviour,
        /// bit-identical output). Forwarded to `hybridRecall(cueTerms:)`.
        public let cueTerms: [String]
        /// Maximum drawers fed into synthesis, applied AFTER reranking.
        /// The most cue-relevant drawers survive the cap, not the most
        /// recent. nil = no truncation (previous behaviour). Trial 2
        /// measured client timeouts when synthesis ran over a 200-drawer
        /// pool; the cap bounds the synthesizer's work while the cue-pool
        /// bound keeps the ranking lane wide.
        public let cap: Int?
        /// Raw query text for the SCORED second lane (BM25 + vector via
        /// the GLK `.unionBest`/`.raw` request — the lane PreciseRecall's
        /// coarse grab uses). The scored lane reaches relevant rows that
        /// share NO cue terms with the question — the semantic gap that
        /// capped the lexical-only pool at 34/50 misses in trial 4. nil =
        /// lexical-only grounding (previous behaviour).
        public let query: String?
        /// Exclude rows gated by provenance sensitivity before synthesis.
        /// MCP read surfaces enable this because recall-frame sensitivity
        /// filters cover the adjective axis, not provenance bits 30...35.
        public let excludeProvenanceSensitive: Bool

        public init(
            frame: RecallFrame,
            tuning: RecallFrameTuning = .default,
            cueTerms: [String] = [],
            cap: Int? = nil,
            query: String? = nil,
            excludeProvenanceSensitive: Bool = false
        ) {
            self.frame = frame
            self.tuning = tuning
            self.cueTerms = cueTerms
            self.cap = cap
            self.query = query
            self.excludeProvenanceSensitive = excludeProvenanceSensitive
        }
    }

    /// Wide bound on each grounding lane's pool. The cue predicate (lane A)
    /// and the scored search (lane B) both scope hard already; this bound
    /// only guards pathological matches. 200 measured tolerable end-to-end
    /// (0.1 s rerank after the shingle-cache fix); the user's `cap` bounds
    /// what feeds synthesis, not this.
    public static let groundingPoolBound = 200

    /// Recipe output: the synthesized context document and the number
    /// of drawers it was grounded on.
    public struct Output: Sendable {
        /// The synthesized, provenance-grounded context document. Never
        /// persisted (NeuronKit C-9) — handed to a foundation model.
        public let context: ContextDocument
        /// How many recalled drawers fed the synthesis.
        public let drawerCount: Int

        public init(context: ContextDocument, drawerCount: Int) {
            self.context = context
            self.drawerCount = drawerCount
        }
    }

    public init() {}

    public let name = "grounded_synthesis"
    public let version = "1.0.0"
    public let description =
        "Hybrid-recall a query and synthesize the recalled drawers into a single grounded context document."

    /// Sequences NeuronKit's `hybridRecall` and `ContextSynthesizer`.
    public let requiredCapabilities: [NeuronKitCapability] = [
        .hybridRecall, .synthesize,
    ]

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // Spec B-5: verify capabilities before any substrate touch.
        try verifyCapabilities(required: requiredCapabilities)

        // Capture the recipe-start timestamp once at the entry boundary for
        // paired start/complete telemetry. The clock is read unconditionally
        // regardless of whether monitoring is enabled; it does not affect the
        // returned value.
        let startTs = Date().timeIntervalSince1970
        // Emit cognitionkit.recipe.run with status "start". Pairs with the
        // "complete" emit at the function exit. When monitoring is off, the
        // autoclosure inside emitRecipeStart is never evaluated (off-path cost:
        // one Atomic<Bool>.load(.acquiring) + branch, ~1 ns).
        emitRecipeStart(name: name, ts: startTs)

        // 1. Hybrid recall over the single GLK recall-verb boundary
        //    (NeuronKit B-1). Returns a paged, MMR-reranked stream.
        //
        //    Hydration is forced to .full: ContextSynthesizer extracts
        //    patterns/themes from drawer BODIES, and per spec § 7.3 a
        //    .structured recall returns content as "" (blob loading is
        //    skipped). Synthesizing over structured rows would silently
        //    produce an empty-pattern context — same failure class as the
        //    Contradiction recipe.
        var fullFrame = input.frame
        fullFrame.hydrationLevel = .full
        // Forward cueTerms so the lexical RRF lane ranks by distinct-term-match
        // count. Empty cueTerms = input-order recency (previous behaviour).
        //
        // GROUNDED POOL CONSTRUCTION — the recipe owns both lanes:
        //   Lane A (lexical): the base frame + an OR of contentMatches
        //   predicates over the cue terms, wide-bounded. Reaches rows that
        //   literally contain a distinctive question word.
        //   Lane B (scored): the base frame WITHOUT the cue predicate,
        //   driven by the raw query through the GLK scored search
        //   (`.unionBest`/`.raw`, BM25 + vector). Reaches relevant rows
        //   that share NO question words — the semantic gap measured as
        //   34/50 pool misses in trial 4.
        let grounded = !input.cueTerms.isEmpty
        var laneAFrame = fullFrame
        var scoredLane: ScoredLane? = nil
        if grounded {
            let poolBound = max(input.cap ?? 0, Self.groundingPoolBound)
            laneAFrame.filterChain.append(
                .any(input.cueTerms.map { .contentMatches($0) }))
            laneAFrame.limit = poolBound
            if let query = input.query {
                var laneBFrame = fullFrame
                laneBFrame.limit = poolBound
                scoredLane = ScoredLane(
                    frame: laneBFrame,
                    queryText: query,
                    traceLimit: input.cap ?? input.tuning.pageSize)
            }
        }

        // Lane weighting lives in hybridRecall (the recency-shall-not-
        // dominate invariant): with cue terms and no genuine relevance in
        // the semantic lane it goes lexical-dominant; with a live scored
        // lead block it honors the caller's fusion split. The recipe passes
        // its tuning through untouched.
        let stream = try await hybridRecall(
            laneAFrame,
            handle: estate,
            on: kit,
            tuning: input.tuning,
            cueTerms: input.cueTerms,
            scoredLane: scoredLane
        )

        // 2. Drain every page. hybridRecall reranks the FULL result
        //    before paging, so concatenating page rows in order
        //    preserves the rerank ordering for synthesis. Accumulate
        //    pages (not rows) so the drawer element type stays inferred
        //    and the ambiguous `Drawer` name is never spelled here.
        var pages: [RecallStream.Page] = []
        for await page in stream {
            pages.append(page)
        }
        let recalledRows = pages.flatMap { $0.rows }
        let allRows = input.excludeProvenanceSensitive
            ? recalledRows.filter { $0.sensitivity != .restricted && $0.sensitivity != .secret }
            : recalledRows

        // Apply cap BEFORE synthesis so the synthesizer's work is bounded
        // by the user limit, not the pool size. Cap is applied after reranking:
        // the most cue-relevant drawers survive, not the most recent.
        // Type inference retains the element type without spelling the ambiguous
        // `Drawer` name (see file-header type-resolution note).
        // nil cap = no truncation (previous behaviour).
        let rowsToSynthesize = input.cap.map { Array(allRows.prefix($0)) } ?? allRows

        // 3. Synthesize over the (capped, reranked) set, presented as one
        //    terminal page. Read-only (C-9): no estate write.
        let combined = RecallStream.Page(
            rows: rowsToSynthesize, pageIndex: 0, isLast: true
        )
        // Cue-grounded: every ranked survivor must be VISIBLE in the
        // document, so keyInsights scales to the synthesized set (trial 3
        // measured 30/35 misses with the answer ranked into the capped set
        // but invisible behind the historical 3-row excerpt). Digest mode
        // keeps the 3-row default.
        let context = try await ContextSynthesizer.synthesize(
            from: combined,
            estate: estate,
            maxKeyInsights: input.cueTerms.isEmpty ? 3 : rowsToSynthesize.count
        )

        // Emit cognitionkit.recipe.run with status "complete". The step_count
        // tag is the number of drawers that fed synthesis (post-cap) so the
        // telemetry reflects the synthesizer's actual work. Byte-identical to
        // the output whether monitoring is on or off (C-Det: additive telemetry).
        emitRecipeComplete(name: name, stepCount: rowsToSynthesize.count, ts: startTs)

        return Output(context: context, drawerCount: rowsToSynthesize.count)
    }
}
