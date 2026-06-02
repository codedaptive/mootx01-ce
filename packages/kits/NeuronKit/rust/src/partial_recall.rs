//! Partial-cue recall — per-block fingerprint matching (Lens 7, Associative):
//! the NeuronKit reasoning surface over SubstrateML's `PartialStateRecall`.
//! The 256-bit drawer fingerprint is FOUR independent 64-bit similarity
//! blocks — structure (0), concept/lattice (1), lineage-temporal (2),
//! channel/source (3). Querying one block instead of the whole fingerprint
//! gives "memories that FEEL structurally like this" vs "memories ABOUT this
//! concept" vs "memories FROM this period" — three different recalls from one
//! cue. The match/differ split scores "similar in X, different in Y".
//!
//! Paired with the Swift version (`Sources/NeuronKit/Lenses/PartialRecall.swift`).
//! Layer B-1: the block-Hamming math lives in SubstrateML; this is a thin
//! surface. CognitionKit sequences it (compute the fingerprints, pick blocks).

use std::collections::HashSet;

use substrate_ml::partial_state_recall::PartialStateRecall;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::RowId;

/// Block index of each fingerprint family (cookbook §2.x fingerprint layout).
pub const BLOCK_STRUCTURE: u8 = 0;
pub const BLOCK_CONCEPT: u8 = 1;
pub const BLOCK_TEMPORAL: u8 = 2;
pub const BLOCK_CHANNEL: u8 = 3;

/// Top-`k` rows by partial-match score: high similarity to `anchor` over
/// `match_blocks` AND high difference over `differ_blocks` ("feels like X in
/// these facets, but unlike it in those"). Thin wrapper over SubstrateML's
/// `PartialStateRecall::top_k`. The caller excludes the anchor row if present.
pub fn partial_recall(
    anchor: Fingerprint256,
    rows: &[(RowId, Fingerprint256)],
    match_blocks: &HashSet<u8>,
    differ_blocks: &HashSet<u8>,
    k: usize,
) -> Vec<(RowId, f64)> {
    PartialStateRecall::top_k(anchor, rows, match_blocks, differ_blocks, k)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a 256-bit fingerprint where each of the four 64-bit blocks is
    /// either all-ones or all-zeros, per `blocks` (true = ones).
    fn fp(blocks: [bool; 4]) -> Fingerprint256 {
        let mut bits = vec![false; 256];
        for (b, &on) in blocks.iter().enumerate() {
            if on {
                for i in (b * 64)..((b + 1) * 64) {
                    bits[i] = true;
                }
            }
        }
        Fingerprint256::from_bits(&bits)
    }

    fn blocks(xs: &[u8]) -> HashSet<u8> {
        xs.iter().copied().collect()
    }

    // PR-1: "feels structurally like the anchor but is conceptually different"
    // — match block 0, differ block 1. A candidate sharing the anchor's
    // structure block but with a different concept block outscores one that is
    // identical everywhere (no conceptual difference to reward).
    #[test]
    fn pr1_structural_match_conceptual_differ_ranks_first() {
        // anchor: structure ones, concept zeros.
        let anchor = fp([true, false, false, false]);
        let rows = vec![
            // same structure (match), different concept (differ) → high score.
            (RowId(1), fp([true, true, false, false])),
            // identical to anchor → structure matches but concept does NOT
            // differ → low score.
            (RowId(2), fp([true, false, false, false])),
        ];
        let out = partial_recall(
            anchor,
            &rows,
            &blocks(&[BLOCK_STRUCTURE]),
            &blocks(&[BLOCK_CONCEPT]),
            2,
        );
        assert_eq!(
            out[0].0,
            RowId(1),
            "structurally-alike-but-conceptually-different ranks first"
        );
        assert!(out[0].1 > out[1].1);
    }

    // PR-2: switching the lens to "ABOUT this concept" (match block 1) surfaces
    // a different memory — the same cue, a different recall.
    #[test]
    fn pr2_block_choice_changes_the_recall() {
        let anchor = fp([true, true, false, false]); // structure + concept ones
        let rows = vec![
            // matches concept, differs structure.
            (RowId(10), fp([false, true, false, false])),
            // matches structure, differs concept.
            (RowId(11), fp([true, false, false, false])),
        ];
        let about = partial_recall(
            anchor,
            &rows,
            &blocks(&[BLOCK_CONCEPT]),
            &blocks(&[BLOCK_STRUCTURE]),
            1,
        );
        assert_eq!(
            about[0].0,
            RowId(10),
            "ABOUT-this-concept surfaces the concept match"
        );
        let feels = partial_recall(
            anchor,
            &rows,
            &blocks(&[BLOCK_STRUCTURE]),
            &blocks(&[BLOCK_CONCEPT]),
            1,
        );
        assert_eq!(
            feels[0].0,
            RowId(11),
            "FEELS-like-this surfaces the structure match"
        );
    }
}
