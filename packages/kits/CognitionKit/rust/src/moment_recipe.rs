//! Moment — temporal fingerprint signature recipe (Lens 1, Time).
//!
//! Accepts pre-fetched fingerprints. `fingerprints_captured_in` is implemented
//! in `LocusKit::DrawerStore` (Swift and Rust), but the Rust `EstateCoordinator`
//! does not yet re-export it as a top-level GLK surface — the Swift port has
//! `GeniusLocusKit.glkFingerprintsCaptured` for this. Callers using the Rust
//! port read fingerprints directly via `DrawerStore::fingerprints_captured_in`
//! and pass them here.
//!
//! Pure function: OR-reduces the primary window fingerprints into a signature
//! and ranks each comparison-window OR-summary by Hamming proximity, delegating
//! entirely to `neuron_kit::moment_signature`. Read-only (B-6, I-6).

use substrate_ml::moment_summary::{MomentSummary, RowLite};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;

pub use neuron_kit::{moment_signature, MomentSignatureResult, WindowRank};

/// Moment recipe output: the OR-reduced window signature and ranked comparison
/// candidates, plus the observation counts.
#[derive(Debug, Clone, PartialEq)]
pub struct MomentOutput {
    pub result: MomentSignatureResult,
    /// Count of fingerprints in the primary window.
    pub window_count: usize,
    /// Count of fingerprints in each comparison window, in input order.
    /// Comparison windows whose fingerprint count was zero contributed
    /// no candidate.
    pub comparison_counts: Vec<usize>,
}

/// OR-reduce the primary window fingerprints into a signature and rank
/// each comparison-window OR-summary by Hamming proximity.
///
/// Empty `window_fingerprints` or empty `candidates` yields a zero
/// signature and empty ranking (B-8 total-over-edge-input posture).
///
/// - `window_fingerprints`: Fingerprints captured in the primary window.
/// - `comparison_fps`: One fingerprint slice per comparison window; windows
///   with no fingerprints contribute no candidate (they are counted but not
///   OR-reduced).
pub fn run_moment(
    window_fingerprints: &[Fingerprint256],
    comparison_fps: &[Vec<Fingerprint256>],
) -> MomentOutput {
    let window_count = window_fingerprints.len();

    // Wrap as RowLite for the lens. `capture_hlc` is not consumed by
    // `moment_signature` (only `.fingerprint` drives OR-reduce and ranking).
    // HLC::ZERO is the correct structural placeholder when the GLK surface
    // returns Fingerprint256 without HLC.
    let primary_rows: Vec<RowLite> = window_fingerprints
        .iter()
        .map(|&fp| RowLite { fingerprint: fp, capture_hlc: HLC::ZERO })
        .collect();

    let mut comparison_counts: Vec<usize> = Vec::with_capacity(comparison_fps.len());
    let mut candidates: Vec<Fingerprint256> = Vec::with_capacity(comparison_fps.len());
    for fps in comparison_fps {
        comparison_counts.push(fps.len());
        if !fps.is_empty() {
            candidates.push(MomentSummary::or_reduce(fps));
        }
    }

    let result = moment_signature(&primary_rows, &candidates);

    MomentOutput { result, window_count, comparison_counts }
}

#[cfg(test)]
mod tests {
    use super::*;

    // CK-MO-1 (Rust): recipe output equals direct lens call on the same shaped input.
    #[test]
    fn ck_mo1_matches_direct_lens_call() {
        // Two distinct fingerprints for the primary window.
        let fp_a = Fingerprint256 { block0: 0x01, block1: 0x00, block2: 0x00, block3: 0x00 };
        let fp_b = Fingerprint256 { block0: 0x10, block1: 0x00, block2: 0x00, block3: 0x00 };
        // One comparison window with one fingerprint.
        let fp_c = Fingerprint256 { block0: 0x11, block1: 0x00, block2: 0x00, block3: 0x00 };

        let window_fps = vec![fp_a, fp_b];
        let comparison_fps = vec![vec![fp_c]];

        // Shape input identically to run_moment and call the lens directly.
        let primary_rows: Vec<RowLite> = window_fps
            .iter()
            .map(|&fp| RowLite { fingerprint: fp, capture_hlc: HLC::ZERO })
            .collect();
        let candidate = MomentSummary::or_reduce(&[fp_c]);
        let expected = moment_signature(&primary_rows, &[candidate]);

        let out = run_moment(&window_fps, &comparison_fps);

        assert_eq!(out.result, expected,
            "run_moment must equal the direct lens call on the same shaped input");
        assert_eq!(out.window_count, 2);
        assert_eq!(out.comparison_counts, vec![1]);
    }

    // CK-MO-2 (Rust): empty primary window yields zero signature and empty ranking.
    #[test]
    fn ck_mo2_empty_primary_is_guarded() {
        let out = run_moment(&[], &[]);
        assert_eq!(out.window_count, 0);
        assert_eq!(out.result.signature, Fingerprint256::ZERO);
        assert!(out.result.ranking.is_empty());
    }

    // CK-MO-3 (Rust): non-empty primary window, no comparison windows → empty ranking.
    #[test]
    fn ck_mo3_no_comparisons_yields_empty_ranking() {
        let fp = Fingerprint256 { block0: 0xAB, block1: 0x00, block2: 0x00, block3: 0x00 };
        let out = run_moment(&[fp], &[]);
        assert!(out.result.ranking.is_empty());
        assert_eq!(out.window_count, 1);
    }
}
