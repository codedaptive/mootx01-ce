// brain/distillation_cycle.rs — Rust mirror of DistillationCycle.swift.
//
// Per-item distillation for GeniusLocusKit — SPEC_DISTILLATION_STORAGE §7.
//
// A distilled representation is a VIEW of one item: five nullable columns
// on the SOURCE drawer row plus one `distillation-features-v1` lane entry
// keyed by the SOURCE drawer id. The factoid-drawer model (room
// "_distilled", `_distilled_from` tunnels, "distillation-daemon"
// provenance) is retired on 1.1.x (§11).
//
// This module supplies the pure decision functions, the pure rendering
// step (`render_distillation`, which delegates the stored text to
// ContextDistillLib), and the lane constants that every distillation
// caller delegates to. Storage I/O lives at the Coordinator
// level where the storage handle is available — see `distill_item` there,
// the single write seam shared by the drain-stage rider, the seeding path,
// and `distill_items_sweep`.

// MARK: - Rendering-path selection

/// Minimum number of reduction units (sentences) an item needs to take the
/// intra-item MATRIX path (§7.4). With M < 3 every feature has df = 1.0,
/// so every pairwise PMI = 0 and the coherence graph fragments — a shorter
/// item takes the token-compaction path (§7.5) instead. Every item
/// distills either way (§13.1); this constant selects the path, it no
/// longer gates production.
///
/// Mirrors the `sentences.count >= 3` branch in Swift `distillItem`.
pub const MIN_INTRA_ITEM_UNITS: usize = 3;

/// Whether an item with `unit_count` reduction units (sentences) takes the
/// matrix path (true) or the short-item compaction path (false). Mirrors
/// the Swift branch in `distillItem`.
pub fn item_is_distillable(unit_count: usize) -> bool {
    unit_count >= MIN_INTRA_ITEM_UNITS
}

/// The §7.5 short-item rendering: the §7.6 compaction transform, with the
/// content itself as the last-resort rendering when compaction eliminates
/// everything (pathological all-stopword content) — §13.1 requires every
/// non-empty item to carry a representation. Mirrors Swift
/// `GeniusLocusKit.compactionRendering(of:)`.
pub fn compaction_rendering(content: &str) -> String {
    let compacted = substrate_ml::token_compaction::compact(content);
    if compacted.is_empty() {
        content.to_string()
    } else {
        compacted
    }
}

/// Render one item's distilled representation and its structural
/// fingerprint — the pure half of `distill_item` (§7.4/§7.5), shared by
/// every caller so the two paths can never drift apart.
///
/// The stored text comes from ContextDistillLib (CDL-02): the intent-span
/// converter receives the verbatim content plus the deterministic
/// categorizer trailer computed FROM that content, keeps only the trailer
/// fields it can anchor in the source, and appends them as a grammar-v1
/// block at the END of the text (where CorpusKit's trailer lexical
/// supplement scans for BM25 tokens). No pronoun rewriting is applied: the
/// representation is exact source text by contract, byte-identical to the
/// Swift port by conformance to the frozen oracle vectors.
///
/// The fingerprint is independent of the text (§8): items with at least
/// `MIN_INTRA_ITEM_UNITS` sentences take the intra-item M×|V| reduction and
/// keep its OR-reduced feature fingerprint; shorter items use the
/// query-fingerprint construction over the content.
///
/// Pure: no storage I/O, no clock. Mirrors the rendering half of Swift
/// `GeniusLocusKit.distillItem(handle:drawerID:content:distillFn:now:)`.
pub fn render_distillation(
    drawer_id: &str,
    content: &str,
) -> (String, substrate_types::fingerprint256::Fingerprint256) {
    use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};

    let sentences: Vec<String> = eidetic_lib::segmenter::sentences(content);
    let fingerprint = if item_is_distillable(sentences.len()) {
        // Matrix path (§7.4): intra-item M×|V| reduction; only its feature
        // fingerprint is consumed here. memory_timestamps stays None ON
        // PURPOSE (W2.5 S6): one item's sentences share the item's single
        // timestamp — equal ages make TypedDecayWeighting's weights cancel
        // in the normalizer (wdf ≡ df), so threading the timestamp is a
        // mathematical no-op. The decay branch is live in the CROSS-ITEM
        // consolidation path (coordinator::compose_and_distill), which also
        // consumes the rendered text.
        let input = DistillationInput::new(
            sentences,
            None,
            drawer_id.to_string(),
            vec![drawer_id.to_string()],
        );
        DistillationPipeline::run(&input, DistillationPipeline::default_extractor, true)
            .feature_fingerprint
    } else {
        // Short-item path (§7.5): fingerprint via the query-fingerprint
        // construction over the content.
        DistillationPipeline::query_fingerprint(content, DistillationPipeline::default_extractor)
    };

    (distilled_representation(content), fingerprint)
}

/// The stored distilled representation for one item's content — the pure
/// text half of `distill_item`, exposed so tests, the trailer-parity report,
/// and tools can compute exactly what the sweep writes. Twin of Swift
/// `GeniusLocusKit.distilledRepresentation(forContent:)`: the converter
/// receives the verbatim content plus the deterministic categorizer trailer
/// computed FROM that content and appends the anchorable fields as a
/// grammar-v1 block at the end of the text. Pure: no I/O, no clock.
pub fn distilled_representation(content: &str) -> String {
    use context_distill_lib::distiller::ContextDistiller;
    use context_distill_lib::input::DistillationInput as ConverterInput;

    // enrichment_trailer returns the grammar-v1 block with the leading space
    // that welded it onto the p2.3 rendering. The converter's trailer grammar
    // is a full match on the bare `(*[ ... ]*)` block — the form the oracle
    // rows carry — so the block is trimmed here; with the space it would be
    // rejected as malformed and silently dropped.
    let trailer = super::enrichment_stage::enrichment_trailer(content).trim().to_string();
    ContextDistiller::new()
        .distill(&ConverterInput::new(content, trailer), crate::DISTILLATION_CONVERTER)
        .ai_text
}

/// The token estimate stored in `distilled_token_count` — the library's
/// estimator, so the stored count equals the oracle's `distilled_tokens_est`
/// for the same text. Twin of Swift `GeniusLocusKit.distilledTokenCount(_:)`.
pub fn distilled_token_count(representation: &str) -> i64 {
    context_distill_lib::digest::estimate_tokens(representation) as i64
}

// MARK: - Distillation lane constants

/// VectorKit model ID for the structural fingerprint distillation lane
/// (§8). Keyed by the SOURCE drawer id; the no-inference Hamming NN
/// structure is the Phase 2 consolidation cluster-detection substrate.
/// No Phase 1 recall route consumes it.
pub const DISTILLATION_LANE_MODEL_ID: &str = "distillation-features-v1";

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn item_distillable_selects_matrix_path_at_three_units() {
        assert!(!item_is_distillable(0));
        assert!(!item_is_distillable(1));
        assert!(!item_is_distillable(2));
        assert!(item_is_distillable(3));
        assert!(item_is_distillable(10));
        assert_eq!(MIN_INTRA_ITEM_UNITS, 3);
    }

    #[test]
    fn compaction_rendering_compacts_normal_content() {
        assert_eq!(
            compaction_rendering("My favorite color is blue."),
            "My favorite color blue."
        );
    }

    #[test]
    fn compaction_rendering_falls_back_to_content_when_compaction_empties() {
        // All-stopword content would compact to "" — the content itself is
        // the last-resort rendering (§13.1 population guarantee).
        assert_eq!(compaction_rendering("the a an really"), "the a an really");
    }
}
