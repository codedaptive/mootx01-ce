//! EstateDivergence — compare two estates' room distributions by
//! Jensen-Shannon / KL divergence (NeuronKit `drift`): low = organized alike,
//! high = they diverge. The coordinator holds both estates, so it's one recipe
//! over two handles.
//!
//! This is NOT the brainstorm's MindOverlap (Lens 9). MindOverlap's defining
//! property is PRIVACY-PRESERVING federation — divergence over the shared
//! hyperplane family computed WITHOUT either side reading the other's content,
//! via the pairing handshake + DP-OR-reduce. That lives in `mind_overlap_recipe`.
//! This recipe reads BOTH estates' distributions directly — it is the
//! non-private, same-device divergence, useful in its own right but not the
//! federated lens. Named for what it actually does.
//!
//! Paired with the Swift version (`Sources/CognitionKit/EstateDivergence.swift`).
//! Pure CognitionKit sequencing: recall each estate via GLK + NeuronKit drift
//! (SubstrateML InformationTheory). Read-only.

use std::collections::{BTreeMap, BTreeSet};

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{drift, DriftScore};

use crate::error::{RecipeRunError, SubstrateError};

/// How two estates' mental models compare. Low `divergence` = convergent.
#[derive(Debug, Clone, PartialEq)]
pub struct EstateDivergence {
    pub divergence: DriftScore,
    pub a_count: usize,
    pub b_count: usize,
}

fn room_counts(drawers: &[locus_kit::drawer::Drawer]) -> BTreeMap<String, f64> {
    let mut m = BTreeMap::new();
    for d in drawers {
        *m.entry(d.room.clone()).or_insert(0.0) += 1.0;
    }
    m
}

fn normalized(vocab: &[String], counts: &BTreeMap<String, f64>, total: usize) -> Vec<f32> {
    vocab
        .iter()
        .map(|k| (counts.get(k).copied().unwrap_or(0.0) / total as f64) as f32)
        .collect()
}

/// Divergence between estate `handle_a` and estate `handle_b` over their room
/// distributions. `make_frame` builds the recall frame for each (called once
/// per estate). Either estate empty ⇒ zero divergence (nothing to compare).
/// Read-only; a recall failure propagates as `RecipeRunError::Substrate`.
pub fn run_estate_divergence<F>(
    coord: &EstateCoordinator,
    handle_a: &EstateHandle,
    handle_b: &EstateHandle,
    make_frame: F,
    now: i64,
) -> Result<EstateDivergence, RecipeRunError>
where
    F: Fn() -> RecallFrame,
{
    let da = coord
        .recall(handle_a, make_frame(), now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let db = coord
        .recall(handle_b, make_frame(), now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let (ac, bc) = (da.len(), db.len());

    if ac == 0 || bc == 0 {
        return Ok(EstateDivergence {
            divergence: DriftScore { jensen_shannon: 0.0, kl_divergence: 0.0 },
            a_count: ac,
            b_count: bc,
        });
    }

    let a_rooms = room_counts(&da);
    let b_rooms = room_counts(&db);
    let mut vocab: BTreeSet<String> = BTreeSet::new();
    for k in a_rooms.keys().chain(b_rooms.keys()) {
        vocab.insert(k.clone());
    }
    let vocab: Vec<String> = vocab.into_iter().collect();
    let p = normalized(&vocab, &a_rooms, ac);
    let q = normalized(&vocab, &b_rooms, bc);

    Ok(EstateDivergence { divergence: drift(&p, &q), a_count: ac, b_count: bc })
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
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn open_estate(coord: &mut EstateCoordinator) -> EstateHandle {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap()
    }

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, room: &str) {
        let frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, NOW).unwrap();
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-MO-1: two estates filed into disjoint rooms (philosophy vs cooking)
    // diverge sharply; the lens computes one mind against another.
    #[test]
    fn ck_ed1_disjoint_minds_diverge() {
        let mut coord = EstateCoordinator::new();
        let a = open_estate(&mut coord);
        let b = open_estate(&mut coord);
        for _ in 0..3 {
            capture(&coord, &a, "philosophy");
        }
        for _ in 0..3 {
            capture(&coord, &b, "cooking");
        }
        let mo = run_estate_divergence(&coord, &a, &b, all, NOW).expect("overlap");
        assert_eq!((mo.a_count, mo.b_count), (3, 3));
        assert!(mo.divergence.jensen_shannon > 0.5, "disjoint minds diverge, got {}", mo.divergence.jensen_shannon);
    }

    // CK-MO-2: two estates organized the same way converge (near-zero divergence).
    #[test]
    fn ck_ed2_aligned_minds_converge() {
        let mut coord = EstateCoordinator::new();
        let a = open_estate(&mut coord);
        let b = open_estate(&mut coord);
        capture(&coord, &a, "philosophy");
        capture(&coord, &b, "philosophy");
        let mo = run_estate_divergence(&coord, &a, &b, all, NOW).expect("overlap");
        assert!(mo.divergence.jensen_shannon.abs() < 1e-5, "aligned minds converge, got {}", mo.divergence.jensen_shannon);
    }
}
