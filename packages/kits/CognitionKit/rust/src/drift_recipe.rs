//! Drift — the conscious "what's changed about you" recipe (Lens 5, Surprise).
//! Recall a set, split it by event time into a before-window and an
//! after-window, build each window's distribution over rooms, and measure how
//! far the after-window has drifted (Jensen-Shannon / KL via NeuronKit
//! `drift`). "Your filing shifted across April."
//!
//! Split is on `event_time` (the memory's event clock, ING-01), not `filed_at`
//! (the ingest clock). For back-dated bulk ingest the two differ; splitting on
//! `filed_at` puts the entire back-dated corpus in the after-window.
//! `event_time` is always non-optional on a Drawer (set eagerly at construction
//! time when the caller does not supply an explicit event time).
//!
//! Paired with the Swift version (`Sources/CognitionKit/Drift.swift`).
//! Pure CognitionKit sequencing: recall via GLK + NeuronKit drift (which
//! surfaces SubstrateML's InformationTheory). Read-only.

use std::collections::{BTreeMap, BTreeSet};

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{drift, DriftScore};

use crate::error::{RecipeRunError, SubstrateError};

/// Drift between the two time windows, with each window's size.
#[derive(Debug, Clone, PartialEq)]
pub struct DriftOutput {
    pub drift: DriftScore,
    pub before_count: usize,
    pub after_count: usize,
}

/// Build a Laplace-smoothed, Float32-renormalized probability distribution
/// over `vocab` from raw `counts`.
///
/// Smoothing strategy: add `EPSILON` to every bin in BOTH windows before
/// normalizing. This guarantees full shared support (no zero bins) so
/// `kl_divergence` never encounters a p>0, q=0 term that it skips, which
/// would otherwise let negative shared-bin terms dominate and produce KL < 0
/// (Gibbs' inequality violation).
///
/// `EPSILON = 0.5` (Jeffreys prior / Krichevsky–Trofimov estimator):
/// conservative enough not to swamp small counts; standard choice for
/// information-theoretic divergence on small multinomials.
///
/// Float32 renormalization: after computing ratios in f64 and casting to f32,
/// divide by the f32 sum to ensure ∑p = 1.0 exactly in f32. Without this,
/// accumulated rounding for N > 1 bins can leave the sum slightly off 1.0,
/// which the `drift` function's caller-is-responsible contract requires.
fn smoothed_distribution(
    vocab: &[String],
    counts: &BTreeMap<String, f64>,
    total: usize,
) -> Vec<f32> {
    const EPSILON: f64 = 0.5;
    let n = vocab.len() as f64;
    let smoothed_total = total as f64 + n * EPSILON;
    let dist: Vec<f32> = vocab
        .iter()
        .map(|k| {
            let raw = counts.get(k).copied().unwrap_or(0.0);
            ((raw + EPSILON) / smoothed_total) as f32
        })
        .collect();
    // Renormalize in f32 so ∑dist = 1.0 at Float32 precision.
    let sum: f32 = dist.iter().sum();
    dist.iter().map(|&v| v / sum).collect()
}

/// Measure room-distribution drift between drawers whose event time is before
/// `split_at` and those at/after it. A window with no drawers yields zero
/// drift (nothing to compare). Read-only; recall failure →
/// `RecipeRunError::Substrate`.
///
/// Split is on `event_time` (the memory's event clock, ING-01), not `filed_at`
/// (the ingest clock). For back-dated bulk ingest the two differ; splitting on
/// `filed_at` would classify a back-dated corpus entirely as after. `event_time`
/// is non-optional on a Drawer and resolves eagerly to `filed_at` at
/// construction when the caller does not supply an explicit event time.
pub fn run_drift(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    split_at: i64,
    now: i64,
) -> Result<DriftOutput, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let mut before: BTreeMap<String, f64> = BTreeMap::new();
    let mut after: BTreeMap<String, f64> = BTreeMap::new();
    let (mut bc, mut ac) = (0usize, 0usize);
    for d in &drawers {
        // Split on event_time (the memory's event clock, ING-01), not
        // filed_at (the ingest clock). For back-dated corpora these differ.
        if d.event_time < split_at {
            *before.entry(d.room.clone()).or_insert(0.0) += 1.0;
            bc += 1;
        } else {
            *after.entry(d.room.clone()).or_insert(0.0) += 1.0;
            ac += 1;
        }
    }

    if bc == 0 || ac == 0 {
        return Ok(DriftOutput {
            drift: DriftScore {
                jensen_shannon: 0.0,
                kl_divergence: 0.0,
            },
            before_count: bc,
            after_count: ac,
        });
    }

    // Shared, aligned support across both windows (BTreeSet ⇒ sorted ⇒
    // deterministic bin order, same discipline as the Swift sorted()).
    let mut vocab: BTreeSet<String> = BTreeSet::new();
    for k in before.keys().chain(after.keys()) {
        vocab.insert(k.clone());
    }
    let vocab: Vec<String> = vocab.into_iter().collect();

    // Laplace-smoothed distributions; see smoothed_distribution() for
    // the rationale (partial-overlap vocabulary, KL ≥ 0 guarantee).
    let p = smoothed_distribution(&vocab, &before, bc);
    let q = smoothed_distribution(&vocab, &after, ac);

    Ok(DriftOutput {
        drift: drift(&p, &q),
        before_count: bc,
        after_count: ac,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;

    const SPLIT: i64 = 1_500;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(1_000, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn capture_at(coord: &EstateCoordinator, h: &EstateHandle, room: &str, when: i64) {
        let frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, when).unwrap();
    }

    /// Capture with an explicit `event_time` different from `now` (the ingest
    /// clock). Mirrors the Swift `captureWithEventTime` test helper. Used to
    /// verify that the drift recipe splits on `event_time`, not `filed_at`.
    fn capture_with_event_time(
        coord: &EstateCoordinator,
        h: &EstateHandle,
        room: &str,
        event_time: i64,
        filed_at: i64,
    ) {
        let mut frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        // Set explicit event_time so the substrate uses it rather than `now`.
        // ING-01: Drawer.event_time = frame.event_time.unwrap_or(now).
        frame.event_time = Some(event_time);
        coord.capture(h, frame, filed_at).unwrap();
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-DR-1: filing moved rooms across the split — early drawers in "study",
    // later in "work" — registers high drift. The estate notices the shift.
    //
    // Threshold note: Laplace smoothing (ε=0.5) over a 2-bin vocabulary
    // reduces the theoretical JS maximum for a 3-vs-3 disjoint partition
    // from 1.0 to ~0.457 bits. A threshold of 0.3 is meaningful (well
    // above zero drift) while remaining robust to the smoothing.
    #[test]
    fn ck_dr1_room_shift_registers_drift() {
        let (coord, h) = coord_with_parent();
        for _ in 0..3 {
            capture_at(&coord, &h, "study", 1_000);
        }
        for _ in 0..3 {
            capture_at(&coord, &h, "work", 2_000);
        }
        let out = run_drift(&coord, &h, all(), SPLIT, 3_000).expect("drift");
        assert_eq!((out.before_count, out.after_count), (3, 3));
        assert!(
            out.drift.jensen_shannon > 0.3,
            "a full room shift is high drift, got {}",
            out.drift.jensen_shannon
        );
    }

    // CK-DR-2: same rooms across the split — no drift.
    #[test]
    fn ck_dr2_stable_filing_no_drift() {
        let (coord, h) = coord_with_parent();
        capture_at(&coord, &h, "study", 1_000);
        capture_at(&coord, &h, "study", 2_000);
        let out = run_drift(&coord, &h, all(), SPLIT, 3_000).expect("drift");
        assert!(
            out.drift.jensen_shannon.abs() < 1e-5,
            "stable filing ⇒ no drift, got {}",
            out.drift.jensen_shannon
        );
    }

    // CK-DR-4: split on event_time, not filed_at (ING-01 two-clock).
    // All drawers are ingested at `filed_at = 5_000` (same ingest instant).
    // Their explicit event_times straddle SPLIT (1_500). The before/after
    // partition must follow event_time.
    #[test]
    fn ck_dr4_split_uses_event_time_not_filed_at() {
        let (coord, h) = coord_with_parent();

        // Past event time — before-window via event_time even though
        // filed_at = 5_000 (after SPLIT).
        for _ in 0..3 {
            capture_with_event_time(&coord, &h, "study", 1_000, 5_000);
        }

        // Future event time — after-window via event_time.
        for _ in 0..3 {
            capture_with_event_time(&coord, &h, "work", 2_000, 5_000);
        }

        // SPLIT = 1_500; all filed_at = 5_000.
        // A filed_at split would classify every drawer as after (5_000 >= 1_500).
        // An event_time split correctly yields 3 before, 3 after.
        let out = run_drift(&coord, &h, all(), SPLIT, 10_000).expect("drift");
        assert_eq!(
            (out.before_count, out.after_count),
            (3, 3),
            "event_time split: 3 before, 3 after; filed_at split would give 0, 6"
        );
        assert!(
            out.drift.jensen_shannon > 0.3,
            "full room shift between event_time windows should be high drift, got {}",
            out.drift.jensen_shannon
        );
    }

    // CK-DR-5: partial-overlap vocabulary (before = {study, work},
    // after = {work, lab}). Without Laplace smoothing the absent bin produces
    // a degenerate distribution causing KL to go negative (Gibbs' violation).
    // With smoothing KL ≥ 0 and JS ≥ 0 must hold.
    #[test]
    fn ck_dr5_partial_overlap_kl_non_negative() {
        let (coord, h) = coord_with_parent();

        // Before-window: two rooms.
        capture_with_event_time(&coord, &h, "study", 1_000, 5_000);
        capture_with_event_time(&coord, &h, "work",  1_000, 5_000);

        // After-window: overlaps on "work" but adds "lab", drops "study".
        capture_with_event_time(&coord, &h, "work", 2_000, 5_000);
        capture_with_event_time(&coord, &h, "lab",  2_000, 5_000);

        let out = run_drift(&coord, &h, all(), SPLIT, 10_000).expect("drift");

        // Gibbs' inequality: KL divergence must be ≥ 0 unconditionally.
        // A negative value means the histogram builder produced invalid
        // distributions (partial support without smoothing).
        assert!(
            out.drift.kl_divergence >= 0.0,
            "KL divergence must be non-negative (Gibbs); got {}",
            out.drift.kl_divergence
        );
        assert!(
            out.drift.jensen_shannon >= 0.0,
            "Jensen-Shannon must be non-negative; got {}",
            out.drift.jensen_shannon
        );
    }
}
