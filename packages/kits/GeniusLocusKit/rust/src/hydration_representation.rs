// hydration_representation.rs — the recall-hydration representation
// selector. Rust twin of HydrationRepresentation.swift.
//
// The selector affects ONLY what text hydrates into results; it never
// affects which results match or how they rank. Every variant is computed
// at read time from the verbatim `content` column: the distilled rendering
// is produced inline by ContextDistillLib (Encoder Rerank contract sheet §9)
// and the tokenized variants run the token-compaction transform. Nothing
// here is stored — these are renderings, not columns.

use locus_kit::drawer::Drawer;

/// Which representation of a drawer's text hydrates into a recall result.
/// Wire spellings match the Swift raw values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationRepresentation {
    /// The verbatim `content` column (the default).
    Content,
    /// The inline distilled rendering of `content`.
    Distilled,
    /// `content` passed through the token-compaction transform at read.
    ContentTokenized,
    /// The inline distilled rendering passed through the token-compaction
    /// transform at read.
    DistilledTokenized,
}

impl HydrationRepresentation {
    /// Parse the wire spelling. Mirrors the Swift raw values.
    pub fn from_wire(name: &str) -> Option<Self> {
        match name {
            "content" => Some(Self::Content),
            "distilled" => Some(Self::Distilled),
            "content_tokenized" => Some(Self::ContentTokenized),
            "distilled_tokenized" => Some(Self::DistilledTokenized),
            _ => None,
        }
    }
}

/// The inline distilled rendering of one item's content: the converter
/// (`crate::DISTILLATION_CONVERTER`) receives the verbatim text and selects
/// the exact source spans around operative intent. Pure — no I/O, no clock —
/// and byte-identical across the Swift and Rust ports by conformance to the
/// library's frozen oracle vectors. Measured at 17 ms per 4.9k-character
/// record, which is why it runs at read time instead of being stored. Twin
/// of Swift `GeniusLocusKit.distilledRendering(of:)`.
pub fn distilled_rendering(content: &str) -> String {
    use context_distill_lib::distiller::ContextDistiller;
    use context_distill_lib::input::DistillationInput;

    ContextDistiller::new()
        .distill(&DistillationInput::new(content, ""), crate::DISTILLATION_CONVERTER)
        .ai_text
}

/// The library's token estimate for a rendering, so the per-hit token counts
/// recall surfaces report equal the oracle's `distilled_tokens_est` for the
/// same text. Twin of Swift `GeniusLocusKit.estimatedTokenCount(of:)`.
pub fn estimated_token_count(text: &str) -> i64 {
    context_distill_lib::digest::estimate_tokens(text) as i64
}

/// Resolve the hydrated text for `drawer` under `selector`. Pure: every
/// variant is derived from `drawer.content` at read time; nothing is stored.
/// Mirrors Swift `HydrationRepresentation.resolve(for:)`.
pub fn resolve_hydration_representation(
    selector: HydrationRepresentation,
    drawer: &Drawer,
) -> String {
    use substrate_ml::token_compaction::compact;
    match selector {
        HydrationRepresentation::Content => drawer.content.clone(),
        HydrationRepresentation::ContentTokenized => compact(&drawer.content),
        HydrationRepresentation::Distilled => distilled_rendering(&drawer.content),
        HydrationRepresentation::DistilledTokenized => {
            compact(&distilled_rendering(&drawer.content))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drawer(content: &str) -> Drawer {
        Drawer::new("d1", content, "parent", "tester", 0, "m1")
    }

    #[test]
    fn content_variants_read_the_column() {
        let d = drawer("The original body.");
        assert_eq!(
            resolve_hydration_representation(HydrationRepresentation::Content, &d),
            "The original body."
        );
        assert_eq!(
            resolve_hydration_representation(HydrationRepresentation::ContentTokenized, &d),
            "Original body."
        );
    }

    #[test]
    fn distilled_variants_render_inline_from_content() {
        let body = "The reactor schedule moved to March. Sarah approved the reactor plan. \
                    The reactor uptime is twelve percent better.";
        let d = drawer(body);
        let rendered = resolve_hydration_representation(HydrationRepresentation::Distilled, &d);
        assert_eq!(rendered, distilled_rendering(body), "the selector is the inline converter");
        assert!(!rendered.is_empty());
        assert_eq!(
            resolve_hydration_representation(HydrationRepresentation::DistilledTokenized, &d),
            substrate_ml::token_compaction::compact(&rendered)
        );
        assert!(estimated_token_count(&rendered) > 0);
    }

    #[test]
    fn wire_spellings_round_trip() {
        for (name, sel) in [
            ("content", HydrationRepresentation::Content),
            ("distilled", HydrationRepresentation::Distilled),
            ("content_tokenized", HydrationRepresentation::ContentTokenized),
            ("distilled_tokenized", HydrationRepresentation::DistilledTokenized),
        ] {
            assert_eq!(HydrationRepresentation::from_wire(name), Some(sel));
        }
        assert_eq!(HydrationRepresentation::from_wire("bogus"), None);
    }
}
