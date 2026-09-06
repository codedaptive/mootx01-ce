// HydrationRepresentation.swift
//
// The recall-hydration representation selector.
//
// The selector affects ONLY what text hydrates into results; it never
// affects which results match or how they rank. Every variant is computed
// at read time from the verbatim `content` column: the distilled rendering
// is produced inline by ContextDistillLib (Encoder Rerank contract sheet §9)
// and the tokenized variants run the token-compaction transform. Nothing
// here is stored — these are renderings, not columns.

import ContextDistillLib
import Foundation
import LocusKit
import SubstrateML

/// Which representation of a drawer's text hydrates into a recall result.
/// Raw values are the wire spellings clients use.
public enum HydrationRepresentation: String, Sendable, CaseIterable {
    /// The verbatim `content` column (the default).
    case content
    /// The inline distilled rendering of `content`.
    case distilled
    /// `content` passed through the token-compaction transform at read.
    case contentTokenized = "content_tokenized"
    /// The inline distilled rendering passed through the token-compaction
    /// transform at read.
    case distilledTokenized = "distilled_tokenized"
}

public extension HydrationRepresentation {
    /// Resolve the hydrated text for `drawer` under this selector. Pure: every
    /// variant is derived from `drawer.content` at read time; nothing is
    /// stored. Mirrors Rust `resolve_hydration_representation`.
    func resolve(for drawer: Drawer) -> String {
        switch self {
        case .content:
            return drawer.content
        case .contentTokenized:
            return TokenCompaction.compact(drawer.content)
        case .distilled:
            return GeniusLocusKit.distilledRendering(of: drawer.content)
        case .distilledTokenized:
            return TokenCompaction.compact(GeniusLocusKit.distilledRendering(of: drawer.content))
        }
    }
}

public extension GeniusLocusKit {

    /// The converter that produces every distilled rendering: intent-span
    /// v23.2, the attributed peer-dialogue ruleset. Readers that need the
    /// converter (CognitionKit recipes, the ARIA hydration path) take it from
    /// here rather than from ContextDistillLib directly, so the choice of
    /// converter is made in exactly one place. Twin of Rust
    /// `DISTILLATION_CONVERTER`.
    static var distillationConverter: ContextDistillConverter { .intentSpanV23Attributed }

    /// The inline distilled rendering of one item's content: the converter
    /// receives the verbatim text and selects the exact source spans around
    /// operative intent. Pure — no I/O, no clock — and byte-identical across
    /// the Swift and Rust ports by conformance to the library's frozen oracle
    /// vectors. Measured at 17 ms per 4.9k-character record, which is why it
    /// runs at read time instead of being stored. Twin of Rust
    /// `distilled_rendering`.
    static func distilledRendering(of content: String) -> String {
        ContextDistiller().distill(
            ContextDistillLib.DistillationInput(original: content),
            converter: distillationConverter
        ).aiText
    }

    /// The library's token estimate for a rendering, so the per-hit token
    /// counts recall surfaces report equal the oracle's `distilled_tokens_est`
    /// for the same text. Twin of Rust `estimated_token_count`.
    static func estimatedTokenCount(of text: String) -> Int64 {
        Int64(estimateTokens(text))
    }
}
