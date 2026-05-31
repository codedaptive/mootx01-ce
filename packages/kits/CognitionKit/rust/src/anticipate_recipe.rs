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
//! The SUCCESS signal is user-confirmation, now a LIVE event source: the
//! `confirm` verb (`Estate.mutate(.confirm)`) transitions a row to
//! UserConfirmed in both ports. Differentiation needs to see BOTH confirmed
//! and unconfirmed observations of the same action→outcome, but the recall
//! confirmation axis is single-class (a frame returns either confirmed or
//! unconfirmed rows, never both — absent a confirmation filter the evaluator
//! defaults to the UserConfirmed ceiling). So this recipe OWNS that axis: it
//! unions a confirmed recall (success = true) and an unconfirmed recall
//! (success = false), both scoped by the caller's `frame` with any
//! confirmation-level filter stripped. Both the action→outcome MAPPING and the
//! success DIFFERENTIATION are real end-to-end today.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::{Filter, RecallFrame};
use neuron_kit::{anticipate, ActionObservation, ActionPrediction};

use crate::error::{RecipeRunError, SubstrateError};

/// Drop the confirmation-level filters (`UserConfirmed` / `ModelConfirmedOnly`
/// / `Unconfirmed`) from a chain — the recipe re-adds exactly one per recall,
/// so a caller-supplied confirmation filter must not survive to conflict.
fn without_confirmation_level(chain: &[Filter]) -> Vec<Filter> {
    chain
        .iter()
        .filter(|f| {
            !matches!(
                f,
                Filter::UserConfirmed | Filter::ModelConfirmedOnly | Filter::Unconfirmed
            )
        })
        .cloned()
        .collect()
}

/// Learn from the recalled memories which capture channels (actions) reach
/// `target_outcome` (a content-kind raw value), top `k` with at least
/// `min_observations` seen. Unions a confirmed recall (successes) and an
/// unconfirmed recall (non-successes) under the caller's scope so the learned
/// success rate differentiates. Read-only; recall failure →
/// `RecipeRunError::Substrate`.
pub fn run_anticipate(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    target_outcome: u8,
    k: usize,
    min_observations: u32,
    now: i64,
) -> Result<Vec<ActionPrediction>, RecipeRunError> {
    let base = without_confirmation_level(&frame.filter_chain);

    let mut confirmed_frame = frame.clone();
    confirmed_frame.filter_chain = {
        let mut c = base.clone();
        c.push(Filter::UserConfirmed);
        c
    };
    let mut unconfirmed_frame = frame.clone();
    unconfirmed_frame.filter_chain = {
        let mut c = base;
        c.push(Filter::Unconfirmed);
        c
    };

    let confirmed = coord
        .recall(handle, confirmed_frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let unconfirmed = coord
        .recall(handle, unconfirmed_frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // success = whether the row is user-confirmed; the confirmed recall yields
    // the true observations, the unconfirmed recall the false ones. The two
    // sets are disjoint (confirmation ≥ 1 vs == 0), so no row is double-counted.
    let observations: Vec<ActionObservation> = confirmed
        .iter()
        .chain(unconfirmed.iter())
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
    use locus_kit::frames::{CaptureFrame, MutationKind};
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

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, channel: CaptureChannel, kind: ContentKind) -> String {
        let mut frame = CaptureFrame::new(
            "content",
            channel,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        frame.kind = kind;
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn all() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // CK-AC-1: the action→outcome mapping flows end-to-end — the channel used
    // to capture Code-kind memories surfaces as the action for that outcome.
    // (This fixture exercises the MAPPING with no confirmations; CK-AC-3
    // exercises the success DIFFERENTIATION via the live confirm verb.)
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

    // CK-AC-3: success DIFFERENTIATION end-to-end via the live confirm verb.
    // Two channels both reach the Code outcome, but Typed captures get
    // confirmed (succeed) far more often than Voiced ones — so for "reach
    // Code," Typed ranks above Voiced with a higher learned success rate. This
    // is the half the confirm verb unblocked: before it, both rates were 0.
    #[test]
    fn ck_ac3_confirmation_differentiates_success() {
        let (coord, h) = coord_with_parent();
        // Typed→Code ×4, confirm 3 (3/4 succeed).
        for i in 0..4 {
            let id = capture(&coord, &h, CaptureChannel::Typed, ContentKind::Code);
            if i < 3 {
                coord.mutate(&h, &id, MutationKind::Confirm, None).expect("confirm");
            }
        }
        // Voiced→Code ×4, confirm 1 (1/4 succeed).
        for i in 0..4 {
            let id = capture(&coord, &h, CaptureChannel::Voiced, ContentKind::Code);
            if i < 1 {
                coord.mutate(&h, &id, MutationKind::Confirm, None).expect("confirm");
            }
        }

        let code = ContentKind::Code.raw_value() as u8;
        let typed = CaptureChannel::Typed.raw_value() as u8;
        let voiced = CaptureChannel::Voiced.raw_value() as u8;
        let pred = run_anticipate(&coord, &h, all(), code, 5, 1, NOW).expect("anticipate");

        assert_eq!(pred[0].action, typed, "the more-confirmed action leads for the Code outcome");
        let t = pred.iter().find(|p| p.action == typed).expect("typed predicted");
        let v = pred.iter().find(|p| p.action == voiced).expect("voiced predicted");
        assert!(t.success_rate > v.success_rate, "Typed {} > Voiced {}", t.success_rate, v.success_rate);
        // Both action→outcome cells saw all four observations (confirmed +
        // unconfirmed unioned), so the rate is differentiation, not coverage.
        assert_eq!(t.count, 4);
        assert_eq!(v.count, 4);
    }
}
