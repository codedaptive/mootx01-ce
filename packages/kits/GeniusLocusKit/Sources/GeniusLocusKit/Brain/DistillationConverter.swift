// DistillationConverter.swift
//
// The product's active dense-context converter: intent-span v23.2, the
// attributed peer-dialogue ruleset (activated 2026-09-03 per the addendum to
// DECISION_CONTEXTDISTILLLIB_2026-09-02). The converter ID is the versioning
// contract for the stored `distilled` representation: it is written to
// `distilled_pipeline_version` on every distillation, beside the SHA-256
// digest of the complete content the representation was rendered from
// (`distilled_source_digest`). The one currency rule below compares both
// against the active converter and the row's content; bumping the converter
// re-distills every estate lazily through the sweep and eagerly through the
// Redistill recipe. The v22 ruleset stays in the library; nothing here
// routes between converters.
//
// Readers below GeniusLocusKit that need the ID (CognitionKit recipes, the
// mootx01 CLI) take it from here rather than from ContextDistillLib directly,
// so the choice of converter is made in exactly one place.

import ContextDistillLib
import LocusKit

public extension GeniusLocusKit {

    /// The converter that produces every stored distilled representation.
    static var distillationConverter: ContextDistillConverter { .intentSpanV23Attributed }

    /// The converter ID written to `distilled_pipeline_version`. A row whose
    /// stored value differs is a regeneration candidate for the sweep.
    static var distillationConverterID: String { distillationConverter.id }

    /// The one representation-currency rule (both ports, one function): a
    /// drawer's stored representation is current iff bit 19 is set, its
    /// converter ID equals `distillationConverterID`, AND its stored source
    /// digest equals `sourceDigest(content)` — the digest of the complete
    /// content beside it. A nil digest (written before the digest column
    /// existed) is stale by definition. Every regeneration decision — the
    /// sweep, the drain-stage rider, seeding, and the awaiting-reindex
    /// probe — keys on this rule; the storage-level aggregates in LocusKit
    /// apply the half SQL can see (converter ID and digest NULL-ness).
    ///
    /// Requires a fully hydrated drawer: at `.structured` hydration
    /// `content` is empty and the digest comparison would read stale.
    /// Pure: no I/O, no clock.
    static func distilledRepresentationIsCurrent(_ drawer: Drawer) -> Bool {
        drawer.hasCurrentRepresentation
            && drawer.distilledPipelineVersion == distillationConverterID
            && drawer.distilledSourceDigest == sourceDigest(drawer.content)
    }

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
