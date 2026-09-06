// brain/fingerprint_lane.rs — Rust mirror of FingerprintLane.swift.
//
// The per-item structural fingerprint lane: one `distillation-features-v1`
// SynapseKit entry keyed by the SOURCE drawer id. It is a search structure,
// not a rendering — the no-inference Hamming NN substrate read by the
// structural-fingerprint recall lane (Lane B), by vague recall, and by the
// consolidation cycle's cluster detection.
//
// Writers: the encode rider (`EstateCoordinator::wire_corpus_on_encoded`)
// after each drained batch, the hint-seeding path (`seed_default_wings`)
// after it indexes a hint, and the impatient capture path. All three call
// `write_structural_fingerprint`, so the lane is populated exactly when a
// drawer becomes searchable in the corpus. The consolidation cycle writes
// the lane for the vague items it creates through the same store call.
//
// Determinism: the fingerprint is a function of (content,
// `DistillationPipeline::default_extractor`) only — identical content gives
// an identical lane entry on both ports.

use std::sync::Arc;

use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};
use substrate_types::fingerprint256::Fingerprint256;
use synapsekit::VectorStore;

/// SynapseKit model ID for the structural fingerprint lane. Keyed by the
/// SOURCE drawer id. The string is a storage key shared with the Swift port
/// (`distillationLaneModelID`) and with every estate already on disk, so it
/// is never renamed.
pub const DISTILLATION_LANE_MODEL_ID: &str = "distillation-features-v1";

/// Minimum number of reduction units (sentences) an item needs to take the
/// intra-item MATRIX path. With fewer than three units every feature has
/// df = 1.0, so every pairwise PMI is 0 and the coherence graph fragments —
/// a shorter item takes the probe construction instead. Mirrors the
/// `sentences.count >= 3` branch in Swift `writeStructuralFingerprint`.
pub const MIN_INTRA_ITEM_UNITS: usize = 3;

/// Whether an item with `unit_count` reduction units (sentences) takes the
/// matrix path (true) or the short-item probe construction (false).
pub fn takes_matrix_path(unit_count: usize) -> bool {
    unit_count >= MIN_INTRA_ITEM_UNITS
}

/// The short-cluster rendering the consolidation cycle stores when a cluster
/// has fewer than three sentences: the token-compaction transform, with the
/// content itself as the last-resort rendering when compaction eliminates
/// everything (pathological all-stopword content), so every consolidated
/// item carries a non-empty rendering. Mirrors Swift
/// `GeniusLocusKit.compactionRendering(of:)`.
pub fn compaction_rendering(content: &str) -> String {
    let compacted = substrate_ml::token_compaction::compact(content);
    if compacted.is_empty() {
        content.to_string()
    } else {
        compacted
    }
}

/// One drawer's structural fingerprint — the pure half of
/// `write_structural_fingerprint`.
///
/// Items with three or more sentences take the intra-item M×|V| reduction
/// with the contract-pinned default extractor and keep its OR-reduced
/// feature fingerprint; shorter items use the `query_fingerprint`
/// construction over the content, the same construction recall probes with.
/// A zero fingerprint means no extracted features. Pure: no storage I/O, no
/// clock. Mirrors the fingerprint half of Swift `writeStructuralFingerprint`.
pub fn structural_fingerprint(drawer_id: &str, content: &str) -> Fingerprint256 {
    // Same segmenter the corpus Chunker uses, so the reduction units are
    // consistent with the dense index.
    let sentences: Vec<String> = eidetic_lib::segmenter::sentences(content);
    if takes_matrix_path(sentences.len()) {
        // memory_timestamps stays None ON PURPOSE: one item's sentences share
        // the item's single timestamp — equal ages make TypedDecayWeighting's
        // weights cancel in the normalizer (wdf ≡ df), so threading the
        // timestamp is a mathematical no-op. The decay branch is live in the
        // CROSS-ITEM path (coordinator::compose_and_distill), which also
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
        DistillationPipeline::query_fingerprint(content, DistillationPipeline::default_extractor)
    }
}

/// Compute one drawer's structural fingerprint and replace its
/// `distillation-features-v1` lane entry.
///
/// A FREE function, not a coordinator method: the drain-stage `on_encoded`
/// callback is a `'static` closure that cannot borrow the coordinator, so the
/// VectorStore is passed explicitly. That is what lets the rider, the seeding
/// path, and the impatient capture path traverse this same call tree.
/// VectorStore absence is non-fatal: the lane is simply dark, matching the
/// estate's semantic-tier wiring. A zero fingerprint (no extracted features)
/// writes nothing. `add_vector` upserts on (item_id, model_id), so a
/// re-indexed drawer replaces its entry rather than accumulating one per
/// encode. `now` is epoch milliseconds, passed in and never read here.
///
/// Returns true when a lane entry was written. Mirrors Swift
/// `GeniusLocusKit.writeStructuralFingerprint(handle:drawerID:content:now:)`.
pub fn write_structural_fingerprint(
    vector_store: Option<&Arc<VectorStore>>,
    drawer_id: &str,
    content: &str,
    now: i64,
) -> bool {
    let Some(vs) = vector_store else { return false };
    if content.is_empty() {
        return false;
    }
    let fingerprint = structural_fingerprint(drawer_id, content);
    if fingerprint == Fingerprint256::ZERO {
        return false;
    }
    vs.add_vector(drawer_id, &fingerprint, DISTILLATION_LANE_MODEL_ID, "1", now)
        .is_ok()
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_path_starts_at_three_units() {
        assert!(!takes_matrix_path(0));
        assert!(!takes_matrix_path(1));
        assert!(!takes_matrix_path(2));
        assert!(takes_matrix_path(3));
        assert!(takes_matrix_path(10));
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
        // the last-resort rendering (population guarantee).
        assert_eq!(compaction_rendering("the a an really"), "the a an really");
    }

    #[test]
    fn write_without_vector_store_is_a_dark_lane() {
        assert!(!write_structural_fingerprint(
            None,
            "d1",
            "Batch S4 used Rhenium wire. Tests on Rhenium passed. Labs shipped Rhenium early.",
            0
        ));
    }
}
