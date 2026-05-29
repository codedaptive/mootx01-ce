// moment_summary.rs
//
// Moment-summary fingerprint per cookbook § 8.7. Mirror of
// glref-swift-MomentSummary.swift.

use substrate_types::hlc::HLC;
use substrate_types::fingerprint256::Fingerprint256;

// Phase 6.8 (decision 2026-05-28 §6.6): TimeRange moved to
// substrate-types. Re-exported so `crate::moment_summary::TimeRange`
// keeps resolving for any historical paths.
pub use substrate_types::time_range::TimeRange;

/// Row stub holding only what moment-summary needs.
#[derive(Debug, Clone, Copy)]
pub struct RowLite {
    pub fingerprint: Fingerprint256,
    pub capture_hlc: HLC,
}

pub struct MomentSummary;

impl MomentSummary {
    /// OR-reduce a slice of fingerprints.
    pub fn or_reduce(fps: &[Fingerprint256]) -> Fingerprint256 {
        let mut acc = Fingerprint256::ZERO;
        for f in fps {
            acc.block0 |= f.block0;
            acc.block1 |= f.block1;
            acc.block2 |= f.block2;
            acc.block3 |= f.block3;
        }
        acc
    }

    /// Compute the moment-summary fingerprint over rows satisfying
    /// `active_during(row, window)`.
    pub fn summarize<F>(rows: &[RowLite], window: TimeRange, active_during: F) -> Fingerprint256
    where
        F: Fn(&RowLite, TimeRange) -> bool,
    {
        let matching: Vec<Fingerprint256> = rows
            .iter()
            .filter(|r| active_during(r, window))
            .map(|r| r.fingerprint)
            .collect();
        Self::or_reduce(&matching)
    }

    /// Convenience predicate: row was captured within the window.
    pub fn captured_during(row: &RowLite, window: TimeRange) -> bool {
        window.contains(row.capture_hlc)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hlc(t: i64) -> HLC {
        HLC::new(t, 0, 1)
    }

    fn row(t: i64, fp: Fingerprint256) -> RowLite {
        RowLite { fingerprint: fp, capture_hlc: hlc(t) }
    }

    #[test]
    fn empty_input_is_zero() {
        let result = MomentSummary::summarize(
            &[],
            TimeRange::new(hlc(0), hlc(100)),
            MomentSummary::captured_during,
        );
        assert_eq!(result, Fingerprint256::ZERO);
    }

    #[test]
    fn no_match_is_zero() {
        let r = row(50, Fingerprint256::new(0xFF, 0, 0, 0));
        let result = MomentSummary::summarize(
            &[r],
            TimeRange::new(hlc(200), hlc(300)), // window after capture
            MomentSummary::captured_during,
        );
        assert_eq!(result, Fingerprint256::ZERO);
    }

    #[test]
    fn or_reduce_two_fingerprints() {
        let a = Fingerprint256::new(0xFF00, 0x0001, 0, 0);
        let b = Fingerprint256::new(0x00FF, 0x0010, 0xABCD, 0);
        let result = MomentSummary::or_reduce(&[a, b]);
        assert_eq!(result.block0, 0xFFFF);
        assert_eq!(result.block1, 0x0011);
        assert_eq!(result.block2, 0xABCD);
        assert_eq!(result.block3, 0);
    }

    #[test]
    fn idempotent_under_duplication() {
        let r = row(50, Fingerprint256::new(0x1234, 0x5678, 0, 0));
        let window = TimeRange::new(hlc(0), hlc(100));
        let once = MomentSummary::summarize(&[r], window, MomentSummary::captured_during);
        let twice =
            MomentSummary::summarize(&[r, r], window, MomentSummary::captured_during);
        assert_eq!(once, twice);
    }

    #[test]
    fn commutative_under_permutation() {
        let r1 = row(10, Fingerprint256::new(0xFF00, 0, 0, 0));
        let r2 = row(20, Fingerprint256::new(0x00FF, 0x0001, 0, 0));
        let r3 = row(30, Fingerprint256::new(0, 0, 0xABCD, 0));
        let window = TimeRange::new(hlc(0), hlc(100));
        let a = MomentSummary::summarize(&[r1, r2, r3], window, MomentSummary::captured_during);
        let b = MomentSummary::summarize(&[r3, r1, r2], window, MomentSummary::captured_during);
        assert_eq!(a, b);
    }

    #[test]
    fn monotone_under_inclusion() {
        let r1 = row(10, Fingerprint256::new(0xFF00, 0, 0, 0));
        let r2 = row(20, Fingerprint256::new(0x00FF, 0, 0, 0));
        let window = TimeRange::new(hlc(0), hlc(100));
        let small = MomentSummary::summarize(&[r1], window, MomentSummary::captured_during);
        let large = MomentSummary::summarize(&[r1, r2], window, MomentSummary::captured_during);
        // Every bit set in `small` is set in `large`.
        assert_eq!(small.block0 & large.block0, small.block0);
        assert_eq!(small.block1 & large.block1, small.block1);
        assert_eq!(small.block2 & large.block2, small.block2);
        assert_eq!(small.block3 & large.block3, small.block3);
    }
}
