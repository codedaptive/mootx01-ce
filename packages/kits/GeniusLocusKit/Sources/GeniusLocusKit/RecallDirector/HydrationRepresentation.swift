// HydrationRepresentation.swift
//
// The recall-hydration representation selector — SPEC_DISTILLATION_STORAGE
// §10.1/§10.2.
//
// The selector affects ONLY what text hydrates into results; it never
// affects which results match or how they rank (§9 search isolation).
// Tokenized variants are computed at retrieval time and never stored —
// they are renderings, not columns.

import Foundation
import LocusKit
import SubstrateML

/// Which representation of a drawer's text hydrates into a recall result
/// (SPEC §10.1). Raw values are the wire spellings clients use.
public enum HydrationRepresentation: String, Sendable, CaseIterable {
    /// The verbatim `content` column (default — today's behavior).
    case content
    /// The `distilled` column (§10.2 fallback to content when NULL).
    case distilled
    /// `content` passed through the §7.6 token-compaction transform at read.
    case contentTokenized = "content_tokenized"
    /// `distilled` passed through the §7.6 transform at read (§10.2
    /// fallback to `content_tokenized` when NULL).
    case distilledTokenized = "distilled_tokenized"
}

/// The resolved hydration text for one result row.
public struct HydratedRepresentation: Sendable, Equatable {
    /// The text to surface for this row under the requested selector.
    public let text: String
    /// True when a DISTILLED variant was requested but the row carries no
    /// representation yet (pre-sweep, or the §7.3 edit-to-regeneration
    /// window), so the corresponding CONTENT variant was served instead.
    /// A per-result response field, never stored state (§10.2). Always
    /// false for the content variants — no fallback can occur.
    public let servedFromContent: Bool

    public init(text: String, servedFromContent: Bool) {
        self.text = text
        self.servedFromContent = servedFromContent
    }
}

public extension HydrationRepresentation {
    /// Resolve the hydrated text for `drawer` under this selector. Pure —
    /// tokenized variants run the §7.6 transform at read; nothing is
    /// stored (§10.1). Mirrors Rust `resolve_hydration_representation`.
    func resolve(for drawer: Drawer) -> HydratedRepresentation {
        switch self {
        case .content:
            return HydratedRepresentation(text: drawer.content, servedFromContent: false)
        case .contentTokenized:
            return HydratedRepresentation(
                text: TokenCompaction.compact(drawer.content), servedFromContent: false)
        case .distilled:
            if let distilled = drawer.distilled {
                return HydratedRepresentation(text: distilled, servedFromContent: false)
            }
            // §10.2 fallback: the corresponding content variant, marked.
            return HydratedRepresentation(text: drawer.content, servedFromContent: true)
        case .distilledTokenized:
            if let distilled = drawer.distilled {
                return HydratedRepresentation(
                    text: TokenCompaction.compact(distilled), servedFromContent: false)
            }
            return HydratedRepresentation(
                text: TokenCompaction.compact(drawer.content), servedFromContent: true)
        }
    }
}
