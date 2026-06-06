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
/// Constants retained for use with `HashSet<u8>` in `partial_recall`.
pub const BLOCK_STRUCTURE: u8 = 0;
pub const BLOCK_CONCEPT: u8 = 1;
pub const BLOCK_TEMPORAL: u8 = 2;
pub const BLOCK_CHANNEL: u8 = 3;

/// One of the four 64-bit fingerprint families in the 256-bit drawer
/// fingerprint. The raw value is the block index (0–3).
///
/// Mirrors `FingerprintBlock` (Swift `PartialRecall.swift`, SPEC § 7.6).
/// Use `as_block_index()` to convert to the `u8` block index consumed by
/// `partial_recall`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FingerprintBlock {
    /// Block 0: structural fingerprint (tree/list/paragraph topology).
    Structure = 0,
    /// Block 1: concept/lattice fingerprint (semantic category anchoring).
    Concept = 1,
    /// Block 2: lineage-temporal fingerprint (provenance and time shape).
    Temporal = 2,
    /// Block 3: channel/source fingerprint (origin and trust provenance).
    Channel = 3,
}

impl FingerprintBlock {
    /// The raw `u8` block index, matching the corresponding `BLOCK_*`
    /// constant. Use this when building the `HashSet<u8>` for `partial_recall`.
    pub fn as_block_index(self) -> u8 {
        self as u8
    }
}

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
                bits[b * 64..(b + 1) * 64].fill(true);
            }
        }
        Fingerprint256::from_bits(&bits)
    }

    fn blocks(xs: &[u8]) -> HashSet<u8> {
        xs.iter().copied().collect()
    }

    fn blocks_from(fb: &[FingerprintBlock]) -> HashSet<u8> {
        fb.iter().map(|b| b.as_block_index()).collect()
    }

    // FB-1: FingerprintBlock::as_block_index() returns the correct raw u8 for
    // each case, matching the corresponding BLOCK_* constant.
    #[test]
    fn fb1_as_block_index_matches_constants() {
        assert_eq!(FingerprintBlock::Structure.as_block_index(), BLOCK_STRUCTURE);
        assert_eq!(FingerprintBlock::Concept.as_block_index(), BLOCK_CONCEPT);
        assert_eq!(FingerprintBlock::Temporal.as_block_index(), BLOCK_TEMPORAL);
        assert_eq!(FingerprintBlock::Channel.as_block_index(), BLOCK_CHANNEL);
    }

    // FB-2: Using FingerprintBlock enum variants via blocks_from() produces
    // the same recall results as using raw BLOCK_* constants.
    #[test]
    fn fb2_fingerprint_block_enum_produces_same_recall_as_constants() {
        let anchor = fp([true, false, false, false]); // structure ones, rest zeros
        let rows = vec![
            (RowId(1), fp([true, true, false, false])), // matches structure, differs concept
            (RowId(2), fp([true, false, false, false])), // identical to anchor
        ];
        // Using raw constants.
        let raw_out = partial_recall(
            anchor,
            &rows,
            &blocks(&[BLOCK_STRUCTURE]),
            &blocks(&[BLOCK_CONCEPT]),
            2,
        );
        // Using typed enum.
        let enum_out = partial_recall(
            anchor,
            &rows,
            &blocks_from(&[FingerprintBlock::Structure]),
            &blocks_from(&[FingerprintBlock::Concept]),
            2,
        );
        assert_eq!(raw_out, enum_out, "enum and constant paths produce identical results");
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
