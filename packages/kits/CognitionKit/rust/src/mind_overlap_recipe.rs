//! MindOverlap — the conscious "where two minds converge vs diverge" recipe
//! (Lens 9, Federated), privacy-preserving. Each estate's drawers are
//! fingerprinted under a SHARED hyperplane family (so the spaces are
//! comparable) and reduced to ONE differentially-private aggregate (NeuronKit
//! `dp_summary`); the two aggregates are compared (`summary_overlap`). The
//! comparison touches only the DP summaries — never either estate's individual
//! memories. "The moat": overlap computed without either side reading the
//! other's content.
//!
//! This is the REAL MindOverlap, distinct from `estate_divergence_recipe`
//! (which reads both estates' room distributions directly). Paired with the
//! Swift version (`Sources/CognitionKit/MindOverlap.swift`). Read-only.
//!
//! The shared family + shared DP seed are derived deterministically from both
//! estate UUIDs (the role the pairing handshake plays — a shared nonce so both
//! sides reduce into comparable, comparably-noised spaces). The full federation
//! transport (PairingHandshake exchange across a real boundary) is the wiring
//! above this; the privacy-preserving COMPUTATION is here.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_fingerprint::EstateFingerprintFamilies;
use locus_kit::filter::RecallFrame;
use neuron_kit::{dp_summary, summary_overlap};
use substrate_types::fingerprint256::Fingerprint256;

use crate::error::{RecipeRunError, SubstrateError};

/// Privacy-preserving overlap of two estates. `overlap` in `[0,1]`: 1 =
/// convergent (organized into the same fingerprint space), → 0 = divergent.
#[derive(Debug, Clone, PartialEq)]
pub struct MindOverlap {
    pub overlap: f64,
    pub a_count: usize,
    pub b_count: usize,
}

/// Default differential-privacy budget for the aggregate. epsilon high enough
/// that the aggregate is informative on modest estates; delta/k per the DP
/// reduction's contract.
const EPSILON: f64 = 8.0;
const DELTA: f64 = 1e-6;
// k-anonymity > 1 so only bits SHARED by several memories survive the
// reduction — the summary becomes the estate's dominant structure, not a
// near-all-ones saturation (k=1 keeps any bit any single drawer sets, which
// saturates and makes every estate look identical).
const K_ANONYMITY: usize = 3;

/// Compute the privacy-preserving overlap between estate `handle_a` and estate
/// `handle_b`. Reads each estate independently, reduces each to a DP summary
/// under a shared family + seed, and compares only the summaries. Either estate
/// empty ⇒ overlap 0. Read-only; recall failure → `RecipeRunError::Substrate`.
pub fn run_mind_overlap<F>(
    coord: &EstateCoordinator,
    handle_a: &EstateHandle,
    handle_b: &EstateHandle,
    make_frame: F,
    now: i64,
) -> Result<MindOverlap, RecipeRunError>
where
    F: Fn() -> RecallFrame,
{
    // Shared family key + DP seed from both estate UUIDs (symmetric), so both
    // sides fingerprint into the same space and add comparable DP noise.
    let uuid_a = coord
        .estate_for(handle_a)
        .map_err(|e| SubstrateError::new("estate", format!("{e:?}")))?
        .estate_uuid()
        .to_string();
    let uuid_b = coord
        .estate_for(handle_b)
        .map_err(|e| SubstrateError::new("estate", format!("{e:?}")))?
        .estate_uuid()
        .to_string();
    let shared_key = if uuid_a <= uuid_b {
        format!("{uuid_a}|{uuid_b}")
    } else {
        format!("{uuid_b}|{uuid_a}")
    };
    let seed = substrate_types::fnv::hash64(&shared_key);
    let families = EstateFingerprintFamilies::new(shared_key);

    let summarize = |handle: &EstateHandle| -> Result<(Fingerprint256, usize), RecipeRunError> {
        let drawers = coord
            .recall(handle, make_frame(), now)
            .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
        let fps: Vec<Fingerprint256> = drawers.iter().map(|d| families.fingerprint(d)).collect();
        let summary = dp_summary(&fps, EPSILON, DELTA, K_ANONYMITY, seed);
        Ok((summary, drawers.len()))
    };

    let (summary_a, ac) = summarize(handle_a)?;
    let (summary_b, bc) = summarize(handle_b)?;

    if ac == 0 || bc == 0 {
        return Ok(MindOverlap {
            overlap: 0.0,
            a_count: ac,
            b_count: bc,
        });
    }

    Ok(MindOverlap {
        overlap: summary_overlap(summary_a, summary_b),
        a_count: ac,
        b_count: bc,
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
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    // Fixed UUID per estate so the shared family + DP seed are deterministic
    // (the Laplace noise is seeded from the estate UUIDs — random UUIDs would
    // make the noise, and the test, flaky). Uses `with_storage` to pin the
    // estate UUID; all other construction sites use `InMemoryDrawerStore::new`.
    fn open_estate(coord: &mut EstateCoordinator, uuid: [u8; 16]) -> EstateHandle {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::from_bytes(uuid)));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::with_storage(storage, NOW, None).unwrap());
        coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap()
    }

    // The fingerprint encodes the LATTICE anchor (concept block), structure,
    // and channel — not raw text. So two estates are "convergent" when they
    // share lattice anchors, "divergent" when they don't; `udc` is what makes
    // the comparison meaningful.
    fn capture(coord: &EstateCoordinator, h: &EstateHandle, content: &str, room: &str, udc: &str) {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc(udc),
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

    // CK-MO-1: two estates with the SAME memories overlap more than an estate
    // and one with disjoint memories — computed only from the DP summaries
    // (the comparison never reads either estate's drawers). The privacy-
    // preserving overlap distinguishes convergent from divergent minds.
    #[test]
    fn ck_mo1_convergent_overlaps_more_than_divergent() {
        let mut coord = EstateCoordinator::new();
        let a = open_estate(&mut coord, [1; 16]);
        let twin = open_estate(&mut coord, [2; 16]); // same memories as A
        let other = open_estate(&mut coord, [3; 16]); // disjoint memories

        // A and its twin share content AND room (structure/lattice/channel
        // blocks match — only the per-row lineage block differs); "other" is
        // disjoint on content AND room. Enough drawers that the aggregate
        // signal dominates the DP noise.
        // A and its twin share the same lattice anchors (concepts 1xx);
        // "other" is anchored in a disjoint region (concepts 6xx). The lattice
        // block is what the fingerprint encodes, so this is genuine
        // conceptual convergence vs divergence.
        let phil_udc = ["100", "110", "120", "130", "140", "150"];
        for (i, u) in phil_udc.iter().enumerate() {
            capture(&coord, &a, &format!("philosophy note {i}"), "study", u);
            capture(&coord, &twin, &format!("philosophy note {i}"), "study", u);
        }
        for (i, u) in ["600", "610", "620", "630", "640", "650"]
            .iter()
            .enumerate()
        {
            capture(&coord, &other, &format!("cooking note {i}"), "kitchen", u);
        }

        let conv = run_mind_overlap(&coord, &a, &twin, all, NOW).expect("overlap");
        let div = run_mind_overlap(&coord, &a, &other, all, NOW).expect("overlap");
        assert!(
            conv.overlap > div.overlap,
            "convergent minds overlap more: {} vs {}",
            conv.overlap,
            div.overlap
        );
    }

    // CK-MO-2: an empty estate yields zero overlap (guarded).
    #[test]
    fn ck_mo2_empty_guarded() {
        let mut coord = EstateCoordinator::new();
        let a = open_estate(&mut coord, [4; 16]);
        let b = open_estate(&mut coord, [5; 16]);
        capture(&coord, &a, "alpha", "study", "100");
        // b is empty
        let mo = run_mind_overlap(&coord, &a, &b, all, NOW).expect("overlap");
        assert_eq!(mo.overlap, 0.0);
    }
}
