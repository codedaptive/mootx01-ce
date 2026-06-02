//! Contradiction / odd-one-out — the conscious "what doesn't fit" recipe
//! (Lens 5, Surprise). Recall a set, score each drawer's content cohesion with
//! its peers (mean shingle similarity), and flag the ones whose cohesion is
//! anomalously LOW (a negative-z outlier) — the memory in tension with the
//! rest. The estate notices when something doesn't belong.
//!
//! Paired with the Swift version (`Sources/CognitionKit/Contradiction.swift`).
//! Pure CognitionKit sequencing: recall via GLK + NeuronKit
//! `shingle_similarity` (cohesion) + NeuronKit `anomalies` (which surfaces
//! SubstrateML's AnomalyDetection). Read-only.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{anomalies, shingle_similarity};

use crate::error::{RecipeRunError, SubstrateError};

/// The odd-ones-out: drawer ids whose cohesion with the recalled set is
/// anomalously low, plus how many drawers were considered.
#[derive(Debug, Clone, PartialEq)]
pub struct ContradictionOutput {
    pub outliers: Vec<String>,
    pub considered: usize,
}

/// Flag drawers that don't fit the recalled set: cohesion[i] = mean content
/// shingle-similarity of drawer i to the others; a drawer whose cohesion is a
/// negative-z outlier (below the set, beyond `threshold`) is in tension.
/// Needs at least 3 drawers to define "fit". Read-only; recall failure →
/// `RecipeRunError::Substrate`.
pub fn run_contradiction(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    threshold: f32,
    now: i64,
) -> Result<ContradictionOutput, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let n = drawers.len();
    if n < 3 {
        return Ok(ContradictionOutput { outliers: Vec::new(), considered: n });
    }

    // Per-drawer cohesion: mean shingle-similarity to every other drawer.
    let mut cohesion = vec![0.0_f32; n];
    for i in 0..n {
        let mut sum = 0.0_f32;
        for j in 0..n {
            if i != j {
                sum += shingle_similarity(&drawers[i].content, &drawers[j].content);
            }
        }
        cohesion[i] = sum / (n - 1) as f32;
    }

    // Low-cohesion outliers (negative z) are the contradictions.
    let outliers: Vec<String> = anomalies(&cohesion, threshold)
        .into_iter()
        .filter(|a| a.z_score < 0.0)
        .map(|a| drawers[a.index].id.clone())
        .collect();

    Ok(ContradictionOutput { outliers, considered: n })
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

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        (coord, h)
    }

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, content: &str) -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-CN-1: three mutually-similar memories plus one totally unrelated one —
    // the unrelated drawer is flagged as the odd-one-out (its cohesion is the
    // low outlier). The estate spots the memory in tension, end-to-end.
    #[test]
    fn ck_cn1_unrelated_memory_is_flagged() {
        let (coord, h) = coord_with_parent();
        capture(&coord, &h, "the quick brown fox jumps over the lazy dog");
        capture(&coord, &h, "the quick brown fox runs past the lazy dog");
        capture(&coord, &h, "a quick brown fox and a lazy dog");
        let odd = capture(&coord, &h, "zzz qqq vvv mmm kkk www");

        // threshold 1.5 sits in the gap: with n=4 the stark low outlier reaches
        // z ≈ -1.73, while a coherent set's small spread cannot exceed it.
        let out = run_contradiction(&coord, &h, all(), 1.5, NOW).expect("contradiction");
        assert_eq!(out.considered, 4);
        assert!(out.outliers.contains(&odd), "the unrelated memory is the odd-one-out: {:?}", out.outliers);
    }

    // CK-CN-2: a coherent set (identical content ⇒ uniform cohesion, zero
    // spread) has no contradictions — the anomaly scan's zero-spread guard.
    #[test]
    fn ck_cn2_coherent_set_no_outliers() {
        let (coord, h) = coord_with_parent();
        capture(&coord, &h, "the quick brown fox jumps");
        capture(&coord, &h, "the quick brown fox jumps");
        capture(&coord, &h, "the quick brown fox jumps");
        let out = run_contradiction(&coord, &h, all(), 1.5, NOW).expect("contradiction");
        assert!(out.outliers.is_empty(), "a coherent set has no odd-one-out: {:?}", out.outliers);
    }
}
