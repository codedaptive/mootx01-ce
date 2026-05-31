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

        public init(
            frame: RecallFrame,
            tuning: RecallFrameTuning = .default
        ) {
            self.frame = frame
            self.tuning = tuning
        }
    }

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

        // 1. Hybrid recall over the single GLK recall-verb boundary
        //    (NeuronKit B-1). Returns a paged, MMR-reranked stream.
        let stream = try await hybridRecall(
            input.frame,
            handle: estate,
            on: kit,
            tuning: input.tuning
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
        let allRows = pages.flatMap { $0.rows }

        // 3. Synthesize over the full recalled set, presented as one
        //    terminal page. Read-only (C-9): no estate write.
        let combined = RecallStream.Page(
            rows: allRows, pageIndex: 0, isLast: true
        )
        let context = try await ContextSynthesizer.synthesize(
            from: combined, estate: estate
        )

        return Output(context: context, drawerCount: allRows.count)
    }
}
