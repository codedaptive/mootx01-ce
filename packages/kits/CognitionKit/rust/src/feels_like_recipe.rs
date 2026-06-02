//! FeelsLike / AboutThis / FromThen — the conscious partial-cue recall recipe
//! (Lens 7, Associative). One anchor memory, three different recalls depending
//! which fingerprint block you query: memories that FEEL structurally like it,
//! that are ABOUT the same concept, or that are FROM the same period. The cue
//! is one drawer; the lens is which facet you match on.
//!
//! Rust-only today (Swift version contracted, SPEC C-7). Sequencing: recall via GLK, compute each
//! drawer's 4-block fingerprint via LocusKit's `EstateFingerprintFamilies`,
//! and rank by NeuronKit `partial_recall` (SubstrateML PartialStateRecall).
//! The estate-free String drawer ids are mapped to the recall primitive's
//! `RowId(u128)` by position and mapped back on the way out. Read-only.

use std::collections::HashSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::drawer_fingerprint::EstateFingerprintFamilies;
use locus_kit::filter::RecallFrame;
use neuron_kit::{partial_recall, BLOCK_CONCEPT, BLOCK_STRUCTURE, BLOCK_TEMPORAL};
use substrate_types::RowId;

use crate::error::{RecipeRunError, SubstrateError};

/// Which facet of the anchor to match on — the three recalls one cue affords.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CueMode {
    /// Structurally alike but conceptually different — "feels like this".
    FeelsLike,
    /// Same concept, different structure — "about this".
    AboutThis,
    /// Same period, different concept — "from then".
    FromThen,
}

impl CueMode {
    /// (match_blocks, differ_blocks) for this cue.
    fn blocks(self) -> (HashSet<u8>, HashSet<u8>) {
        let one = |b: u8| -> HashSet<u8> { [b].into_iter().collect() };
        match self {
            CueMode::FeelsLike => (one(BLOCK_STRUCTURE), one(BLOCK_CONCEPT)),
            CueMode::AboutThis => (one(BLOCK_CONCEPT), one(BLOCK_STRUCTURE)),
            CueMode::FromThen => (one(BLOCK_TEMPORAL), one(BLOCK_CONCEPT)),
        }
    }
}

/// One matched memory and its partial-cue score.
#[derive(Debug, Clone, PartialEq)]
pub struct CueMatch {
    pub id: String,
    pub score: f64,
}

/// Recall via `frame`, then rank the recalled memories (excluding the anchor)
/// by partial-cue similarity to `anchor_id` under `mode`, top `k`. Errors with
/// `RecipeRunError::Substrate` if recall fails or `anchor_id` is not in the
/// recalled set. Read-only.
pub fn run_partial_cue_recall(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    anchor_id: &str,
    mode: CueMode,
    k: usize,
    now: i64,
) -> Result<Vec<CueMatch>, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // Fingerprint families seeded by the estate uuid so the four blocks are
    // computed consistently for every drawer in this call.
    let estate = coord
        .estate_for(handle)
        .map_err(|e| SubstrateError::new("estate", format!("{e:?}")))?;
    let families = EstateFingerprintFamilies::new(estate.estate_uuid().to_string());

    // Compute fingerprints; pull out the anchor; map the rest to RowId(index).
    let mut anchor_fp = None;
    let mut rows = Vec::new();
    let mut id_by_index: Vec<String> = Vec::new();
    for d in &drawers {
        let fp = families.fingerprint(d);
        if d.id == anchor_id {
            anchor_fp = Some(fp);
            continue; // never rank the anchor against itself
        }
        rows.push((RowId(id_by_index.len() as u128), fp));
        id_by_index.push(d.id.clone());
    }
    let anchor_fp = anchor_fp.ok_or_else(|| {
        SubstrateError::new("anchor", format!("anchor drawer '{anchor_id}' not in recalled set"))
    })?;

    let (match_blocks, differ_blocks) = mode.blocks();
    let ranked = partial_recall(anchor_fp, &rows, &match_blocks, &differ_blocks, k);

    Ok(ranked
        .into_iter()
        .map(|(rid, score)| CueMatch { id: id_by_index[rid.0 as usize].clone(), score })
        .collect())
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

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, content: &str, room: &str) -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
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

    // CK-FL-1: the lens RUNS end-to-end — computes per-drawer fingerprints,
    // excludes the anchor, and ranks the rest by partial-cue similarity. The
    // anchor never appears in its own results, and every other memory does.
    #[test]
    fn ck_fl1_runs_and_excludes_anchor() {
        let (coord, h) = coord_with_parent();
        let anchor = capture(&coord, &h, "the spec for the lattice anchor system", "study");
        let b = capture(&coord, &h, "another note about lattice anchors and codes", "study");
        let c = capture(&coord, &h, "grocery list eggs milk bread", "kitchen");

        let out = run_partial_cue_recall(&coord, &h, all(), &anchor, CueMode::FeelsLike, 5, NOW)
            .expect("feels-like");
        let ids: Vec<&String> = out.iter().map(|m| &m.id).collect();
        assert!(!ids.contains(&&anchor), "the anchor is never ranked against itself");
        assert!(ids.contains(&&b) && ids.contains(&&c), "every other memory is ranked");
        assert_eq!(out.len(), 2);
    }

    // CK-FL-2: an anchor id not in the recalled set is a substrate error
    // (the cue points at nothing).
    #[test]
    fn ck_fl2_unknown_anchor_errors() {
        let (coord, h) = coord_with_parent();
        capture(&coord, &h, "only memory", "study");
        let err = run_partial_cue_recall(&coord, &h, all(), "no-such-id", CueMode::AboutThis, 5, NOW)
            .unwrap_err();
        assert!(matches!(err, RecipeRunError::Substrate(_)), "unknown anchor is a substrate error, got {err:?}");
    }
}
