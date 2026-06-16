//! Precedence — temporal causality antecedent recipe (Lens 3, Prediction).
//!
//! Accepts pre-fetched `TemporalAuditEntry` slices. `event_lag_pairs` is
//! re-exported from `genius_locus_kit` (via `brain::event_lag_pairs`) on both
//! ports. Callers read entries via `genius_locus_kit::event_lag_pairs` (Rust)
//! or `GeniusLocusKit.glkEventLagPairs` (Swift) and pass the result here.
//!
//! Folds the entry slice into T-matrix deltas using
//! `TemporalCausalityFold::fold`, then ranks the antecedent field-value
//! coordinates most predictive of `target`, delegating to
//! `neuron_kit::precedence`. Read-only.

use substrate_ml::temporal_causality_fold::{
    TemporalAuditEntry, TemporalCausalityFold, TemporalFieldCoord,
};
use substrate_types::hlc::HLC;

pub use neuron_kit::{precedence, AntecedentRank};

/// Precedence recipe output: antecedent ranks and the raw entry count
/// fed to the fold.
#[derive(Debug, Clone, PartialEq)]
pub struct PrecedenceOutput {
    pub antecedents: Vec<AntecedentRank>,
    /// Number of audit entries passed to the fold.
    pub entry_count: usize,
}

/// Fold `entries` into T-matrix deltas and rank the antecedents most
/// predictive of `target`, returning the top `k`.
///
/// `window_minutes` controls the lag-bucket resolution (mirrors
/// `Precedence.foldWindowMinutes` in Swift: 128). `HLC::ZERO` is the
/// cold-start watermark (all entries treated as new).
///
/// Empty `entries`, `k == 0`, or no pair targeting `target` yields an
/// empty antecedent list (B-8).
pub fn run_precedence(
    entries: &[TemporalAuditEntry],
    target: &TemporalFieldCoord,
    k: usize,
    window_minutes: i32,
) -> PrecedenceOutput {
    let entry_count = entries.len();
    // Cold-start: HLC::ZERO treats every entry as new.
    let fold_result = TemporalCausalityFold::fold(entries, window_minutes, HLC::ZERO);
    let antecedents = precedence(&fold_result.deltas, target, k);
    PrecedenceOutput { antecedents, entry_count }
}

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_types::hlc::HLC;

    fn coord(field: &str, value: &str) -> TemporalFieldCoord {
        TemporalFieldCoord::new(field, value)
    }

    fn entry(hlc: HLC, coords: Vec<TemporalFieldCoord>) -> TemporalAuditEntry {
        TemporalAuditEntry::new(hlc, coords)
    }

    // CK-PR-1 (Rust): recipe output equals the direct lens call on the same
    // shaped fold output.
    #[test]
    fn ck_pr1_matches_direct_lens_call() {
        // Two entries: room=lab → room=study, both in the same lag bucket.
        let hlc1 = HLC::new(1000, 0, 0);
        let hlc2 = HLC::new(1001, 0, 0);
        let entries = vec![
            entry(hlc1, vec![coord("room", "string:lab")]),
            entry(hlc2, vec![coord("room", "string:study")]),
        ];
        let target = coord("room", "string:study");

        let fold = TemporalCausalityFold::fold(&entries, 128, HLC::ZERO);
        let expected = precedence(&fold.deltas, &target, 3);

        let out = run_precedence(&entries, &target, 3, 128);

        assert_eq!(out.antecedents, expected,
            "run_precedence must equal the direct lens call on fold output");
        assert_eq!(out.entry_count, 2);
    }

    // CK-PR-2 (Rust): empty entries → empty antecedent list and zero entries (B-8).
    #[test]
    fn ck_pr2_empty_entries_is_guarded() {
        let target = coord("room", "string:study");
        let out = run_precedence(&[], &target, 5, 128);
        assert!(out.antecedents.is_empty());
        assert_eq!(out.entry_count, 0);
    }

    // CK-PR-3 (Rust): k = 0 → empty antecedent list (B-8).
    #[test]
    fn ck_pr3_k_zero_is_guarded() {
        let hlc = HLC::new(1000, 0, 0);
        let entries = vec![entry(hlc, vec![coord("room", "string:lab")])];
        let target = coord("room", "string:study");
        let out = run_precedence(&entries, &target, 0, 128);
        assert!(out.antecedents.is_empty());
    }
}
