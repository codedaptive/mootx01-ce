//! Drift — the conscious "what's changed about you" recipe (Lens 5, Surprise).
//! Recall a set, split it by capture time into a before-window and an
//! after-window, build each window's distribution over rooms, and measure how
//! far the after-window has drifted (Jensen-Shannon / KL via NeuronKit
//! `drift`). "Your filing shifted across April."
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

fn normalized(vocab: &[String], counts: &BTreeMap<String, f64>, total: usize) -> Vec<f32> {
    vocab
        .iter()
        .map(|k| (counts.get(k).copied().unwrap_or(0.0) / total as f64) as f32)
        .collect()
}

/// Measure room-distribution drift between drawers captured before `split_at`
/// and those captured at/after it. A window with no drawers yields zero drift
/// (nothing to compare). Read-only; recall failure → `RecipeRunError::Substrate`.
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
        if d.filed_at < split_at {
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

    // Shared, aligned support across both windows.
    let mut vocab: BTreeSet<String> = BTreeSet::new();
    for k in before.keys().chain(after.keys()) {
        vocab.insert(k.clone());
    }
    let vocab: Vec<String> = vocab.into_iter().collect();
    let p = normalized(&vocab, &before, bc);
    let q = normalized(&vocab, &after, ac);

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

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-DR-1: filing moved rooms across the split — early drawers in "study",
    // later in "work" — registers high drift. The estate notices the shift.
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
            out.drift.jensen_shannon > 0.5,
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
}
