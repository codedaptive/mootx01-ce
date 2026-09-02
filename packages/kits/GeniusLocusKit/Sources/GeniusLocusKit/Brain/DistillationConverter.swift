// DistillationConverter.swift
//
// The product's current dense-context converter (CDL-02). The converter ID is
// the versioning contract for the stored `distilled` representation
// (DECISION_CONTEXTDISTILLLIB_2026-09-02): it is written to
// `distilled_pipeline_version` on every distillation, and every eligibility
// check in the kit compares a row's stored value against it. Bumping the
// converter re-distills every estate lazily through the existing sweep
// (version-mismatch eligibility) and eagerly through the Redistill recipe.
//
// Readers below GeniusLocusKit that need the ID (CognitionKit recipes, the
// mootx01 CLI) take it from here rather than from ContextDistillLib directly,
// so the choice of converter is made in exactly one place.

import ContextDistillLib

public extension GeniusLocusKit {

    /// The converter that produces every stored distilled representation.
    static var distillationConverter: ContextDistillConverter { .intentSpanV22 }

    /// The converter ID written to `distilled_pipeline_version`. A row whose
    /// stored value differs is a regeneration candidate for the sweep.
    static var distillationConverterID: String { distillationConverter.id }

    /// The stored distilled representation for one item's content — the pure
    /// text half of `distillItem`, exposed so tests, the trailer-parity
    /// report, and tools can compute exactly what the sweep writes. The
    /// converter receives the verbatim content and the deterministic
    /// categorizer trailer computed FROM that content, keeps only the trailer
    /// fields it can anchor in the source, and appends them as a grammar-v1
    /// block at the END of the text (where CorpusKit's trailer lexical
    /// supplement scans for BM25 tokens). Pure: no I/O, no clock.
    static func distilledRepresentation(forContent content: String) -> String {
        // EnrichmentStage returns the grammar-v1 block with the leading space
        // that welded it onto the p2.3 rendering. The converter's trailer
        // grammar is a full match on the bare `(*[ ... ]*)` block — the form
        // the oracle rows carry — so the block is stripped here; with the
        // space it would be rejected as malformed and silently dropped.
        let trailer = EnrichmentStage.trailer(forContent: content)
            .trimmingCharacters(in: .whitespaces)
        return ContextDistiller().distill(
            ContextDistillLib.DistillationInput(original: content, enrichmentTrailer: trailer),
            converter: distillationConverter
        ).aiText
    }

    /// The token estimate stored in `distilled_token_count` for a
    /// representation — the library's estimator, so the stored count equals
    /// the oracle's `distilled_tokens_est` for the same text.
    static func distilledTokenCount(_ representation: String) -> Int64 {
        Int64(estimateTokens(representation))
    }
}
