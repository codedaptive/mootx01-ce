//! Moment — temporal fingerprint signature recipe (Lens 1, Time).
//!
//! Reads the primary window's fingerprints from the estate through the GLK
//! surface (`EstateCoordinator::glk_fingerprints_captured`), OR-reduces each
//! comparison window the same way, and surfaces the MomentSignature lens to
//! rank how closely the comparison windows resemble the primary.
//! "What does this moment look like, and which other moments feel most like it?"
//!
//! Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — GLK dormant read
//! (`glk_fingerprints_captured`) + NeuronKit `moment_signature`. Read-only
//! (B-6, I-6). No write verb, `now` passed in, deterministic.
//!
//! Swift peer: `Moment.run` in `Moment.swift` — same flow, same `kit.
//! glkFingerprintsCaptured(in:window:)` reads. Windows are epoch-seconds
//! `(start, end)` pairs here where Swift uses `ClosedRange<Date>`.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use substrate_ml::moment_summary::{MomentSummary, RowLite};
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;

use crate::error::{RecipeRunError, SubstrateError};

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

/// Read the primary window's fingerprints through the GLK surface, OR-reduce
/// each comparison window to a single candidate, and surface the
/// MomentSignature lens.
///
/// An empty primary window or empty candidate list yields a zero signature and
/// empty ranking (B-8 total-over-edge-input posture).
///
/// - `coord`: open GeniusLocusKit coordinator.
/// - `handle`: open estate handle.
/// - `window`: primary window as `(start_epoch, end_epoch)` (closed, epoch
///   seconds); the OR-reduced signature characterises this moment.
/// - `comparison_windows`: windows to rank against the primary signature.
///   Windows with no fingerprints contribute no candidate (counted, skipped).
/// - `now`: current clock tick passed in for determinism (I-6). Not used in the
///   computation; accepted to satisfy the read-only lens-recipe contract (B-6).
pub fn run_moment(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    window: (i64, i64),
    comparison_windows: &[(i64, i64)],
    now: i64,
) -> Result<MomentOutput, RecipeRunError> {
    // `now` is accepted for the read-only lens-recipe contract (B-6) but does
    // not enter the fold; the fingerprint reads are window-scoped.
    let _ = now;

    let window_fingerprints = coord
        .glk_fingerprints_captured(handle, window.0, window.1)
        .map_err(|e| SubstrateError::new("glk_fingerprints_captured", format!("{e:?}")))?;
    let window_count = window_fingerprints.len();

    // Wrap as RowLite for the lens. `capture_hlc` is not consumed by
    // `moment_signature` (only `.fingerprint` drives OR-reduce and ranking).
    // HLC::ZERO is the correct structural placeholder when the GLK surface
    // returns Fingerprint256 without HLC.
    let primary_rows: Vec<RowLite> = window_fingerprints
        .iter()
        .map(|&fp| RowLite { fingerprint: fp, capture_hlc: HLC::ZERO })
        .collect();

    // OR-reduce each comparison window to a single candidate fingerprint.
    // Windows with no fingerprints are skipped so the candidate list stays
    // compact and indices do not corrupt the ranking.
    let mut comparison_counts: Vec<usize> = Vec::with_capacity(comparison_windows.len());
    let mut candidates: Vec<Fingerprint256> = Vec::with_capacity(comparison_windows.len());
    for &(start, end) in comparison_windows {
        let fps = coord
            .glk_fingerprints_captured(handle, start, end)
            .map_err(|e| SubstrateError::new("glk_fingerprints_captured", format!("{e:?}")))?;
        comparison_counts.push(fps.len());
        if !fps.is_empty() {
            candidates.push(MomentSummary::or_reduce(&fps));
        }
    }

    let result = moment_signature(&primary_rows, &candidates);

    Ok(MomentOutput { result, window_count, comparison_counts })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use genius_locus_kit::handle::EstateHandle as GLKHandle;
    use locus_kit::{
        drawer_operational::CaptureChannel,
        drawer_store::DrawerStore,
        drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::{LatticeAnchor, OwnerCredentials},
        frames::CaptureFrame,
    };

    /// Open a fresh in-memory estate. Mirrors the estate builder in
    /// `cognitionkit_telemetry_tests.rs`.
    fn open_estate() -> (EstateCoordinator, GLKHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    /// Capture one drawer at capture-time `now` (epoch seconds). The window
    /// reads filter on this capture time.
    fn capture_at(coord: &mut EstateCoordinator, h: &GLKHandle, content: &str, now: i64) {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, now).unwrap();
    }

    // CK-MO-1 (Rust): recipe output equals a direct lens call on the SAME GLK
    // window reads. Reading both windows through `glk_fingerprints_captured`
    // and feeding the lens directly reproduces `run_moment`'s output exactly.
    #[test]
    fn ck_mo1_matches_direct_lens_call() {
        let (mut coord, handle) = open_estate();

        // Two drawers in the primary window, one in the comparison window.
        capture_at(&mut coord, &handle, "alpha", 1_700_000_100);
        capture_at(&mut coord, &handle, "bravo", 1_700_000_200);
        capture_at(&mut coord, &handle, "charlie", 1_700_001_000);

        let window = (1_700_000_000, 1_700_000_500);
        let comparison_windows = vec![(1_700_000_900, 1_700_001_100)];

        // Build the expected lens input from the same GLK reads run_moment uses.
        let primary_fps = coord
            .glk_fingerprints_captured(&handle, window.0, window.1)
            .unwrap();
        let cmp_fps = coord
            .glk_fingerprints_captured(&handle, comparison_windows[0].0, comparison_windows[0].1)
            .unwrap();
        let primary_rows: Vec<RowLite> = primary_fps
            .iter()
            .map(|&fp| RowLite { fingerprint: fp, capture_hlc: HLC::ZERO })
            .collect();
        let candidate = MomentSummary::or_reduce(&cmp_fps);
        let expected = moment_signature(&primary_rows, &[candidate]);

        let out = run_moment(&coord, &handle, window, &comparison_windows, 1_700_002_000)
            .expect("run_moment must succeed on a live estate");

        assert_eq!(out.window_count, 2, "two drawers captured in the primary window");
        assert_eq!(out.comparison_counts, vec![1], "one drawer in the comparison window");
        assert_eq!(out.result, expected,
            "run_moment must equal the direct lens call on the same window reads");
    }

    // CK-MO-2 (Rust): empty primary window yields zero signature and empty
    // ranking (no drawers captured in range).
    #[test]
    fn ck_mo2_empty_primary_is_guarded() {
        let (coord, handle) = open_estate();
        let out = run_moment(&coord, &handle, (0, 1), &[], 1_700_000_000)
            .expect("run_moment must succeed on an empty estate");
        assert_eq!(out.window_count, 0);
        assert_eq!(out.result.signature, Fingerprint256::ZERO);
        assert!(out.result.ranking.is_empty());
    }

    // CK-MO-3 (Rust): non-empty primary window, no comparison windows →
    // signature present, empty ranking.
    #[test]
    fn ck_mo3_no_comparisons_yields_empty_ranking() {
        let (mut coord, handle) = open_estate();
        capture_at(&mut coord, &handle, "solo", 1_700_000_150);
        let out = run_moment(&coord, &handle, (1_700_000_000, 1_700_000_500), &[], 1_700_001_000)
            .expect("run_moment must succeed");
        assert_eq!(out.window_count, 1);
        assert!(out.result.ranking.is_empty());
    }
}
