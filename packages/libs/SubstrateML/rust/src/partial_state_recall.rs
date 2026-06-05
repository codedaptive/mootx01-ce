// partial_state_recall.rs
//
// Partial-state recall per cookbook § 8.8. Mirror of
// glref-swift-PartialStateRecall.swift.
//
// Input validation convention (MX-Tidy, 2026-06-05):
// Block IDs must be in the domain {0, 1, 2, 3}. An out-of-domain
// block ID corrupts the denominator (counted) without contributing
// to the Hamming distance (ignored by hamming_blocks), producing
// silently wrong scores. `assert!` is used consistently with the
// Rust port's hamming_nn.rs (`assert!(k > 0)`).
// `k` in `top_k` is `usize`, so negative k cannot occur in Rust.

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::RowId;
use std::collections::HashSet;

pub struct PartialStateRecall;

impl PartialStateRecall {
    /// Score a single row against an anchor under the match-and-
    /// differ block constraints.
    ///
    /// Panics (debug) if any block ID is outside {0, 1, 2, 3}.
    pub fn score(
        row_fingerprint: Fingerprint256,
        anchor: Fingerprint256,
        match_blocks: &HashSet<u8>,
        differ_blocks: &HashSet<u8>,
    ) -> f64 {
        assert!(
            match_blocks.iter().all(|&b| b <= 3),
            "match_blocks IDs must be in domain {{0, 1, 2, 3}}"
        );
        assert!(
            differ_blocks.iter().all(|&b| b <= 3),
            "differ_blocks IDs must be in domain {{0, 1, 2, 3}}"
        );
        if match_blocks.is_empty() || differ_blocks.is_empty() {
            return 0.0;
        }
        let match_total_bits = 64.0 * match_blocks.len() as f64;
        let differ_total_bits = 64.0 * differ_blocks.len() as f64;
        let match_d = Self::hamming_blocks(row_fingerprint, anchor, match_blocks) as f64;
        let differ_d = Self::hamming_blocks(row_fingerprint, anchor, differ_blocks) as f64;
        let match_score = 1.0 - (match_d / match_total_bits);
        let differ_score = differ_d / differ_total_bits;
        match_score * differ_score
    }

    /// Top-K rows by descending partial-match score.
    pub fn top_k(
        anchor: Fingerprint256,
        rows: &[(RowId, Fingerprint256)],
        match_blocks: &HashSet<u8>,
        differ_blocks: &HashSet<u8>,
        k: usize,
    ) -> Vec<(RowId, f64)> {
        let mut scored: Vec<(RowId, f64)> = rows
            .iter()
            .map(|(id, fp)| {
                let s = Self::score(*fp, anchor, match_blocks, differ_blocks);
                (*id, s)
            })
            .collect();
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(k);
        scored
    }

    /// Hamming distance over a block subset.
    #[inline]
    pub fn hamming_blocks(
        a: Fingerprint256,
        b: Fingerprint256,
        blocks: &HashSet<u8>,
    ) -> u32 {
        let mut d = 0u32;
        if blocks.contains(&0) { d += (a.block0 ^ b.block0).count_ones(); }
        if blocks.contains(&1) { d += (a.block1 ^ b.block1).count_ones(); }
        if blocks.contains(&2) { d += (a.block2 ^ b.block2).count_ones(); }
        if blocks.contains(&3) { d += (a.block3 ^ b.block3).count_ones(); }
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(items: &[u8]) -> HashSet<u8> {
        items.iter().copied().collect()
    }

    fn fp(b0: u64, b1: u64, b2: u64, b3: u64) -> Fingerprint256 {
        Fingerprint256::new(b0, b1, b2, b3)
    }

    #[test]
    fn identical_scores_zero() {
        // Row identical to anchor fails the differ constraint.
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC);
        let s = PartialStateRecall::score(anchor, anchor, &set(&[0, 1]), &set(&[2, 3]));
        assert_eq!(s, 0.0);
    }

    #[test]
    fn complement_scores_zero() {
        // Row with every bit flipped fails the match constraint.
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC);
        let inverse = fp(!0xFF, !0xAA, !0xBB, !0xCC);
        let s = PartialStateRecall::score(inverse, anchor, &set(&[0, 1]), &set(&[2, 3]));
        assert_eq!(s, 0.0);
    }

    #[test]
    fn ideal_partial_match() {
        // Match perfectly on blocks 0+1, differ maximally on blocks 2+3.
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00);
        let row = fp(0xFF, 0xAA, !0u64, !0u64);
        let s = PartialStateRecall::score(row, anchor, &set(&[0, 1]), &set(&[2, 3]));
        // match_d = 0, differ_d = 128, match_score = 1, differ_score = 1, product = 1.
        assert!((s - 1.0).abs() < 1e-12);
    }

    #[test]
    fn empty_match_blocks_zero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC);
        let row = fp(0, 0, 0, 0);
        let s = PartialStateRecall::score(row, anchor, &HashSet::new(), &set(&[0, 1, 2, 3]));
        assert_eq!(s, 0.0);
    }

    #[test]
    fn empty_differ_blocks_zero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC);
        let row = fp(0, 0, 0, 0);
        let s = PartialStateRecall::score(row, anchor, &set(&[0, 1, 2, 3]), &HashSet::new());
        assert_eq!(s, 0.0);
    }

    #[test]
    fn top_k_orders_descending() {
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00);
        let row_a = (RowId(1), fp(0xFF, 0xAA, !0u64, !0u64)); // ideal: score 1.0
        let row_b = (RowId(2), fp(0xFF, 0xAA, 0xFF, 0xFF));   // partial differ
        let row_c = (RowId(3), fp(0x00, 0x00, !0u64, !0u64)); // perfect differ but no match
        let result = PartialStateRecall::top_k(
            anchor,
            &[row_a, row_b, row_c],
            &set(&[0, 1]),
            &set(&[2, 3]),
            3,
        );
        assert_eq!(result[0].0, RowId(1));
        // row_c has match_score=0 ⇒ score 0 ⇒ tied with worst.
        assert!(result[0].1 > result[1].1);
    }

    #[test]
    fn top_k_respects_k() {
        let anchor = fp(0, 0, 0, 0);
        let rows: Vec<(RowId, Fingerprint256)> =
            (0u128..10).map(|i| (RowId(i), fp(i as u64, 0, !0u64, !0u64))).collect();
        let result = PartialStateRecall::top_k(
            anchor, &rows, &set(&[0, 1]), &set(&[2, 3]), 3);
        assert_eq!(result.len(), 3);
    }
}
