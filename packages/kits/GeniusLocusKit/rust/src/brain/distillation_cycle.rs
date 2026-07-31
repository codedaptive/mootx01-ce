// brain/distillation_cycle.rs — Rust mirror of DistillationCycle.swift.
//
// Per-item distillation for GeniusLocusKit — SPEC_DISTILLATION_STORAGE §7.
//
// A distilled representation is a VIEW of one item: four nullable columns
// on the SOURCE drawer row plus one `distillation-features-v1` lane entry
// keyed by the SOURCE drawer id. The factoid-drawer model (room
// "_distilled", `_distilled_from` tunnels, "distillation-daemon"
// provenance) is retired on 1.1.x (§11).
//
// This module supplies the pure decision functions, the pure rendering
// step (`render_distillation`), and the lane constants that every
// distillation caller delegates to. Storage I/O lives at the Coordinator
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
/// Segments `content` with the canonical cross-leg delimiter algorithm
/// (the same segmenter the corpus Chunker uses, so reduction units line up
/// with the dense index), then takes the MATRIX path when the item has at
/// least `MIN_INTRA_ITEM_UNITS` units and the short-item compaction path
/// otherwise. A degenerate matrix (no features extracted at all) falls back
/// to the short-item transform so §13.1 population holds for every
/// non-empty item.
///
/// Pure: no storage I/O, no clock. Mirrors the rendering half of Swift
/// `GeniusLocusKit.distillItem(handle:drawerID:content:distillFn:now:)`.
pub fn render_distillation(
    drawer_id: &str,
    content: &str,
) -> (String, substrate_types::fingerprint256::Fingerprint256) {
    use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};

    let sentences: Vec<String> = eidetic_lib::segmenter::sentences(content);
    if item_is_distillable(sentences.len()) {
        // Matrix path (§7.4): intra-item M×|V| reduction.
        let input = DistillationInput::new(
            sentences,
            None,
            drawer_id.to_string(),
            vec![drawer_id.to_string()],
        );
        let output =
            DistillationPipeline::run(&input, DistillationPipeline::default_extractor, true);
        let rendering = if output.distilled_text.is_empty() {
            compaction_rendering(content)
        } else {
            output.distilled_text
        };
        (rendering, output.feature_fingerprint)
    } else {
        // Short-item path (§7.5): token-compaction fallback, fingerprint via
        // the query-fingerprint construction over the content.
        (
            compaction_rendering(content),
            DistillationPipeline::query_fingerprint(
                content,
                DistillationPipeline::default_extractor,
            ),
        )
    }
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
