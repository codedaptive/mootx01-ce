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
// This module supplies the pure decision functions and constants the
// Coordinator's `distill_items_sweep` delegates to. Storage I/O lives at
// the Coordinator level where the storage handle is available.

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
