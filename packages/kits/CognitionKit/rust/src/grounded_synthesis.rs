//! GroundedSynthesis — the conscious recall recipe, Rust parity of the
//! Swift `GroundedSynthesis.run(...)`. Take a recall frame, recall over the
//! real GLK recall-verb boundary, rerank (NeuronKit RRF/MMR), and synthesize
//! the full recalled set into one `ContextDocument` for foundation-model
//! consumption.
//!
//! This is the cleanest end-to-end through-line in CognitionKit — it proves
//! `SubstrateML/GLK recall → NeuronKit reasoning → CognitionKit recipe` with
//! nothing faked, no COW branches, no proposal rail. Pure conscious recall +
//! synthesis. Now that the Rust GLK recall verb and NeuronKit
//! `rerank`/`synthesize` are real, the recipe RUNS in Rust, matching Swift.
//!
//! Boundary discipline (B-1/B-2): the recipe holds no substrate state. The
//! only substrate read is the GLK `recall` verb; `synthesize` is read-only
//! (NeuronKit C-9) over the rows already materialised.
//!
//! Error surface: the recipe returns `Result<_, RecipeRunError>` — the
//! capability gate fails as `RecipeRunError::Recipe(RecipeError)`, a recall
//! failure propagates as `RecipeRunError::Substrate(SubstrateError)`. This is
//! the Rust encoding of the Swift recipe's heterogeneous untyped `throws`
//! (`RecipeError` stays the closed, parity-gated guard set).

use std::collections::HashMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{
    rerank, synthesize, ContextDocument, DrawerRow, DrawerRowMeta, RecallFrameTuning, RecallPage,
};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

/// Recipe output: the synthesized, provenance-grounded context document and
/// the number of recalled drawers it was grounded on. Mirrors the Swift
/// `GroundedSynthesis.Output`.
#[derive(Debug, Clone, PartialEq)]
pub struct GroundedOutput {
    pub context: ContextDocument,
    pub drawer_count: usize,
}

/// Run GroundedSynthesis against the estate addressed by `handle`. Sequences
/// the GLK recall verb, NeuronKit `rerank`, and `synthesize`. `tuning`
/// defaults via `RecallFrameTuning::default()` (k=60, λ=0.7, page 50); `now`
/// is explicit per the Rust determinism convention.
pub fn run_grounded_synthesis(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: RecallFrameTuning,
    now: i64,
) -> Result<GroundedOutput, RecipeRunError> {
    // B-5: verify capabilities before any substrate touch. A capability gate
    // failure propagates as RecipeRunError::Recipe.
    verify_capabilities(
        &[NeuronKitCapability::HybridRecall, NeuronKitCapability::Synthesize],
        &shipped_capabilities(),
    )?;

    // 1. Recall over the single GLK recall-verb boundary (now real). A recall
    //    failure (e.g. a stale handle) propagates as RecipeRunError::Substrate.
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // 2. Project to DrawerRow for rerank, and to per-id metadata for
    //    synthesis. Recalled rows are active, hence currently believed; the
    //    caller's recall frame governs which rows surface.
    let rows: Vec<DrawerRow> = drawers
        .iter()
        .map(|d| DrawerRow { id: d.id.clone(), content: d.content.clone() })
        .collect();
    let meta_by_id: HashMap<String, DrawerRowMeta> = drawers
        .iter()
        .map(|d| {
            (
                d.id.clone(),
                DrawerRowMeta {
                    wing: d.wing.clone(),
                    room: d.room.clone(),
                    is_currently_believed: true,
                },
            )
        })
        .collect();

    // RRF/MMR rerank reorders rows; realign the metadata to the reranked
    // order so synthesize's index-matched lookups stay correct.
    let reranked = rerank(&rows, &tuning);
    let meta: Vec<DrawerRowMeta> = reranked
        .iter()
        .map(|r| meta_by_id.get(&r.id).cloned().unwrap_or_default())
        .collect();

    // 3. Synthesize over the full reranked set as one terminal page
    //    (read-only, C-9 — no estate write).
    let page = RecallPage { rows: reranked, page_index: 0, is_last: true };
    let drawer_count = page.rows.len();
    let context = synthesize(&page, &meta);

    Ok(GroundedOutput { context, drawer_count })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::error::RecipeError;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_rows(contents: &[&str]) -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        for c in contents {
            let frame = CaptureFrame::new(
                *c,
                CaptureChannel::Typed,
                "study",
                LatticeAnchor::udc("0"),
                "alice",
                "test-v1",
            );
            coord.capture(&h, frame, NOW).unwrap();
        }
        (coord, h)
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // GS-1: the through-line RUNS — recall the captured rows over the real
    // GLK verb, rerank, and synthesize into a grounded document. drawer_count
    // equals the recalled set; the document is populated.
    #[test]
    fn gs1_recall_and_synthesize_runs() {
        let (coord, h) = coord_with_rows(&[
            "the cat sat on the mat",
            "a dog ran in the park",
            "cats and dogs are pets",
        ]);
        let out =
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW)
                .expect("run");
        assert_eq!(out.drawer_count, 3, "all recalled rows feed synthesis");
        assert!(!out.context.summary.is_empty(), "a grounded document is produced");
        // Active recalled rows are currently believed ⇒ full success rate.
        assert_eq!(out.context.success_rate, 1.0);
    }

    // GS-2: an empty estate recalls nothing; synthesis still yields a
    // well-formed (empty) document — no special-casing, no panic.
    #[test]
    fn gs2_empty_estate_yields_empty_document() {
        let (coord, h) = coord_with_rows(&[]);
        let out =
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW)
                .expect("run");
        assert_eq!(out.drawer_count, 0);
        assert!(out.context.patterns.is_empty());
    }

    // GS-3: the capability gate fires before any substrate touch — a host
    // missing `synthesize` is rejected with MissingCapability (parity of B-5).
    #[test]
    fn gs3_capability_gate_blocks_missing_capability() {
        // Directly exercise the gate the recipe runs first: a host offering
        // only hybridRecall cannot satisfy GroundedSynthesis.
        let err = verify_capabilities(
            &[NeuronKitCapability::HybridRecall, NeuronKitCapability::Synthesize],
            &[NeuronKitCapability::HybridRecall],
        )
        .unwrap_err();
        assert_eq!(err, RecipeError::MissingCapability(NeuronKitCapability::Synthesize));
    }
}
