//! Anticipate — the conscious "what tends to work" recipe (Lens 8, Prediction).
//! Learn, from the estate's own memories, which capture actions reach a target
//! outcome: each drawer is an (action = capture channel, outcome = content
//! kind, success = user-confirmed) observation fed to NeuronKit `anticipate`
//! (SubstrateML's action-outcome matrix). "To reach Y, you tend to do X."
//!
//! This is the REAL action-outcome lens — the learned T-matrix — not the
//! explicit-tunnel successor signal in `tunnel_successor_recipe`. NET-NEW,
//! Rust-first. Read-only; capability gate on Synthesize? No — it sequences a
//! recall + the action-outcome model, neither a declared NeuronKitCapability.
//!
//! Honest dependency (verified, not a disguised caveat): the SUCCESS signal is
//! user-confirmation. Confirmation can only be set by the confirm/mutate verb,
//! which is Brain-layer — `NotSupportedByEstate` in both the Rust and Swift GLK
//! surfaces until the Brain layer ships (the same boundary as the propose
//! sink). So freshly-captured memories are all unconfirmed, and the recipe's
//! learned success rates are uniformly zero until that verb lands: the
//! action→outcome MAPPING is real and flows through today; the success
//! DIFFERENTIATION switches on with the confirm verb. The reasoning itself is
//! proven against varied observations in NeuronKit's `anticipation` fixtures.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::RecallFrame;
use neuron_kit::{anticipate, ActionObservation, ActionPrediction};

use crate::error::{RecipeRunError, SubstrateError};

/// Learn from the recalled memories which capture channels (actions) reach
/// `target_outcome` (a content-kind raw value), top `k` with at least
/// `min_observations` seen. Read-only; recall failure → `RecipeRunError::Substrate`.
pub fn run_anticipate(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    target_outcome: u8,
    k: usize,
    min_observations: u32,
    now: i64,
) -> Result<Vec<ActionPrediction>, RecipeRunError> {
    let drawers = coord
        .recall(handle, frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let observations: Vec<ActionObservation> = drawers
        .iter()
        .map(|d| ActionObservation {
            action: d.capture_channel().raw_value() as u8,
            outcome: d.content_kind().raw_value() as u8,
            success: d.is_user_confirmed(),
        })
        .collect();

    Ok(anticipate(&observations, target_outcome, k, min_observations))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
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

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, channel: CaptureChannel, kind: ContentKind) {
        let mut frame = CaptureFrame::new(
            "content",
            channel,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        frame.kind = kind;
        coord.capture(h, frame, NOW).unwrap();
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-AC-1: the action→outcome mapping flows end-to-end — the channel used
    // to capture Code-kind memories surfaces as the action for that outcome.
    // (Success rates are uniformly 0 until the confirm verb ships; the
    // MAPPING is what's exercised here, the differentiation in NeuronKit AC-*.)
    #[test]
    fn ck_ac1_action_outcome_mapping_flows() {
        let (coord, h) = coord_with_parent();
        for _ in 0..3 {
            capture(&coord, &h, CaptureChannel::Typed, ContentKind::Code);
        }
        for _ in 0..2 {
            capture(&coord, &h, CaptureChannel::Voiced, ContentKind::Prose);
        }
        // Predict actions for outcome = Code.
        let code = ContentKind::Code.raw_value() as u8;
        let pred = run_anticipate(&coord, &h, all(), code, 5, 1, NOW).expect("anticipate");
        let typed = CaptureChannel::Typed.raw_value() as u8;
        assert!(pred.iter().any(|p| p.action == typed), "Typed captures produced the Code outcome");
        // The Voiced→Prose action should NOT appear under the Code outcome.
        let voiced = CaptureChannel::Voiced.raw_value() as u8;
        assert!(!pred.iter().any(|p| p.action == voiced), "Voiced led to Prose, not Code");
    }

    // CK-AC-2: an outcome never produced yields no predictions (guarded).
    #[test]
    fn ck_ac2_unseen_outcome_empty() {
        let (coord, h) = coord_with_parent();
        capture(&coord, &h, CaptureChannel::Typed, ContentKind::Code);
        // FingerprintOnly was never captured.
        let unseen = ContentKind::FingerprintOnly.raw_value() as u8;
        let pred = run_anticipate(&coord, &h, all(), unseen, 5, 1, NOW).expect("anticipate");
        assert!(pred.is_empty());
    }
}
