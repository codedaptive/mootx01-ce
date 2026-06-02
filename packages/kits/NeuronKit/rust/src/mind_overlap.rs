//! MindOverlap — privacy-preserving estate overlap (Lens 9, Federated): the
//! NeuronKit reasoning surface over SubstrateML's DP-OR-reduce. Each estate
//! reduces its fingerprints to ONE differentially-private aggregate; the two
//! aggregates are compared. Neither side's individual memories are ever
//! touched by the comparison — only the DP summaries, which is exactly what
//! would cross a federation boundary. "Where two minds converge vs diverge,
//! computed without either reading the other's content" — the moat.
//!
//! Paired with the Swift version (`Sources/NeuronKit/Lenses/MindOverlap.swift`).
//! Layer B-1: the DP-OR-reduce + Hamming math live in SubstrateML; this shapes
//! a fingerprint set into a private aggregate and two aggregates into an
//! overlap score. CognitionKit sequences it (fingerprint each estate under a
//! SHARED hyperplane family so the aggregates are comparable, then call these).

use std::collections::HashSet;

use substrate_ml::dp_or_reduce::{DPORReduction, DPParameters};
use substrate_ml::partial_state_recall::PartialStateRecall;
use substrate_types::fingerprint256::Fingerprint256;

/// Reduce a fingerprint set to one differentially-private OR-aggregate — the
/// only artifact that need cross a federation boundary. Deterministic for a
/// fixed `seed` (so two estates seeded alike produce comparable noise).
pub fn dp_summary(
    fingerprints: &[Fingerprint256],
    epsilon: f64,
    delta: f64,
    k_anonymity: usize,
    seed: u64,
) -> Fingerprint256 {
    let params = DPParameters::new(epsilon, delta, k_anonymity);
    DPORReduction::reduce(fingerprints, &params, seed)
}

/// Overlap between two DP summaries: `1 - normalized Hamming` over the
/// content/structure/concept blocks (0 structure, 1 concept, 3 channel) — 192
/// bits. 1.0 = identical aggregates (convergent minds); → 0 as they diverge.
/// Computed on the summaries ONLY — neither estate's individual fingerprints
/// are read here.
///
/// Block 2 (lineage-temporal) is DELIBERATELY excluded: it encodes per-row
/// identity (a random lineage id per drawer), so it differs even between two
/// estates holding the very same memory — comparing it across estates is both
/// meaningless and nondeterministic. Cross-estate overlap is about what the
/// estates are ABOUT and how they're structured, not which rows they minted.
pub fn summary_overlap(a: Fingerprint256, b: Fingerprint256) -> f64 {
    let content_blocks: HashSet<u8> = [0, 1, 3].into_iter().collect();
    let h = PartialStateRecall::hamming_blocks(a, b, &content_blocks);
    1.0 - (h as f64 / 192.0)
}

#[cfg(test)]
mod tests {
    use super::*;

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

    // MO-1: the same fingerprint set, reduced under the same seed, yields the
    // same DP aggregate — overlap with itself is total (deterministic DP).
    #[test]
    fn mo1_same_set_same_seed_full_overlap() {
        let set = vec![
            fp([true, false, false, false]),
            fp([true, true, false, false]),
        ];
        let a = dp_summary(&set, 5.0, 1e-6, 1, 0xABCD);
        let b = dp_summary(&set, 5.0, 1e-6, 1, 0xABCD);
        assert_eq!(a, b, "same set + seed ⇒ same DP aggregate");
        assert!(
            (summary_overlap(a, b) - 1.0).abs() < 1e-9,
            "self-overlap is total"
        );
    }

    // MO-2: disjoint fingerprint spaces reduce to different aggregates and
    // overlap less than two convergent ones do.
    #[test]
    fn mo2_disjoint_overlaps_less_than_convergent() {
        let conv_a = vec![fp([true, true, false, false])];
        let conv_b = vec![fp([true, true, false, false])]; // same space
        let div_b = vec![fp([false, false, true, true])]; // opposite blocks

        let sa = dp_summary(&conv_a, 8.0, 1e-6, 1, 0x11);
        let sb_conv = dp_summary(&conv_b, 8.0, 1e-6, 1, 0x11);
        let sb_div = dp_summary(&div_b, 8.0, 1e-6, 1, 0x11);

        let overlap_conv = summary_overlap(sa, sb_conv);
        let overlap_div = summary_overlap(sa, sb_div);
        assert!(
            overlap_conv > overlap_div,
            "convergent minds overlap more than divergent: {overlap_conv} vs {overlap_div}"
        );
    }
}
