//! Bias — the conscious "what you lean toward and away from" recipe (Lens 4,
//! Preference & judgment). Three honest signals over the estate:
//!   - REPRESENTATION: each room's share of the active set vs a reference,
//!     signed (NeuronKit `representation_bias`) — over-weighted = bias FOR,
//!     under-weighted/absent = bias AGAINST.
//!   - DISMISSAL: each room's withdrawal rate — what you actively take back.
//!     A high dismissal rate is "bias against" you enacted, not just absence.
//!   - LEARNED PREFERENCE: a Bradley-Terry utility per room fitted from actual
//!     CURATION choices — confirmations as endorsements, withdrawals as
//!     dismissals (NeuronKit `learned_preference`). This is preference REVEALED
//!     BY CURATION, distinct from representation's capture-volume share: a room
//!     captured heavily but never confirmed ranks high in representation yet
//!     low here — "what you actually keep vs what merely accumulates."
//!
//! Paired with the Swift version (`Sources/CognitionKit/Bias.swift`); the
//! real Lens 4. Pure CognitionKit sequencing: three recalls via GLK
//! (active + confirmed + withdrawn) + NeuronKit `representation_bias`
//! and `learned_preference`. Read-only.
//!
//! All three signals are computable end-to-end today: withdrawal and the
//! confirm verb are both live, so the learned-preference fit reads real
//! endorsement/dismissal events rather than a placeholder.

use std::collections::BTreeMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::State;
use locus_kit::drawer::Drawer;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
use neuron_kit::{learned_preference, representation_bias, CategoryBias, PreferenceStrength};

use crate::error::{RecipeRunError, SubstrateError};

/// What the estate leans toward and away from.
#[derive(Debug, Clone, PartialEq)]
pub struct BiasReport {
    /// Over-represented rooms (bias > 0), most-favored first.
    pub biased_for: Vec<CategoryBias>,
    /// Under-represented / avoided rooms (bias < 0), most-avoided last.
    pub biased_against: Vec<CategoryBias>,
    /// Per-room withdrawal rate (withdrawn / (active + withdrawn)), the
    /// enacted "bias against" — most-dismissed first.
    pub dismissal: Vec<(String, f64)>,
    /// Learned preference per room (Bradley-Terry over confirmations as
    /// endorsements and withdrawals as dismissals), re-centered on neutral —
    /// strongest first. `strength > 0` = preferred by curation, `< 0` =
    /// disfavored, `≈ 0` = no curation signal yet.
    pub learned: Vec<PreferenceStrength>,
}

fn room_counts(drawers: &[Drawer]) -> Vec<(String, f64)> {
    let mut m: BTreeMap<String, f64> = BTreeMap::new();
    for d in drawers {
        *m.entry(d.room.clone()).or_insert(0.0) += 1.0;
    }
    m.into_iter().collect()
}

fn frame_for(state: State) -> RecallFrame {
    // Unconfirmed admits freshly-captured rows (suppresses the default
    // user-confirmed ceiling); the State filter selects active vs withdrawn.
    let mut f = RecallFrame::new(vec![Filter::Unconfirmed, Filter::State(state)]);
    f.hydration_level = HydrationLevel::Structured;
    f.ordering = Ordering::ByCaptureTimeDesc;
    f
}

fn confirmed_frame() -> RecallFrame {
    // The endorsement signal: rows the user confirmed (still active). The
    // UserConfirmed filter admits exactly the confirmed set, the complement of
    // the Unconfirmed frame above.
    let mut f = RecallFrame::new(vec![Filter::UserConfirmed, Filter::State(State::Active)]);
    f.hydration_level = HydrationLevel::Structured;
    f.ordering = Ordering::ByCaptureTimeDesc;
    f
}

/// Compute the estate's representation bias (active rooms vs `reference`),
/// dismissal rates (withdrawn rooms), and learned preference (Bradley-Terry
/// over confirmations vs withdrawals). Read-only; recall failure →
/// `RecipeRunError::Substrate`.
pub fn run_bias(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    reference: &[(String, f64)],
    now: i64,
) -> Result<BiasReport, RecipeRunError> {
    let active = coord
        .recall(handle, frame_for(State::Active), now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let confirmed = coord
        .recall(handle, confirmed_frame(), now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let withdrawn = coord
        .recall(handle, frame_for(State::Withdrawn), now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    let active_counts = room_counts(&active);
    let biases = representation_bias(&active_counts, reference);
    let biased_for: Vec<CategoryBias> = biases.iter().filter(|b| b.bias > 0.0).cloned().collect();
    let biased_against: Vec<CategoryBias> =
        biases.iter().filter(|b| b.bias < 0.0).cloned().collect();

    // Dismissal: withdrawn / (active + withdrawn) per room.
    let active_by_room: BTreeMap<String, f64> = active_counts.iter().cloned().collect();
    let withdrawn_by_room: BTreeMap<String, f64> = room_counts(&withdrawn).into_iter().collect();
    let mut dismissal: Vec<(String, f64)> = withdrawn_by_room
        .iter()
        .map(|(room, w)| {
            let a = active_by_room.get(room).copied().unwrap_or(0.0);
            (room.clone(), w / (a + w))
        })
        .collect();
    dismissal.sort_by(|x, y| {
        y.1.partial_cmp(&x.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| x.0.cmp(&y.0))
    });

    // Learned preference: per-room curation record (confirmations as
    // endorsements, withdrawals as dismissals) over the union of every room
    // that appears in any of the three sets — so an active-but-uncurated room
    // is reported at neutral rather than omitted.
    let confirmed_by_room: BTreeMap<String, f64> = room_counts(&confirmed).into_iter().collect();
    let mut rooms: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    rooms.extend(active_by_room.keys().cloned());
    rooms.extend(confirmed_by_room.keys().cloned());
    rooms.extend(withdrawn_by_room.keys().cloned());
    let records: Vec<(String, i64, i64)> = rooms
        .into_iter()
        .map(|room| {
            let endorsements = confirmed_by_room.get(&room).copied().unwrap_or(0.0) as i64;
            let dismissals = withdrawn_by_room.get(&room).copied().unwrap_or(0.0) as i64;
            (room, endorsements, dismissals)
        })
        .collect();
    let learned = learned_preference(&records)
        .map_err(|e| SubstrateError::new("learned_preference", format!("{e:?}")))?;

    Ok(BiasReport {
        biased_for,
        biased_against,
        dismissal,
        learned,
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
    use locus_kit::frames::{CaptureFrame, MutationKind};

    const NOW: i64 = 1_700_000_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn capture(coord: &EstateCoordinator, h: &EstateHandle, room: &str) -> String {
        let frame = CaptureFrame::new(
            "content",
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord.capture(h, frame, NOW).unwrap().id
    }

    fn reference(pairs: &[(&str, f64)]) -> Vec<(String, f64)> {
        pairs.iter().map(|(l, n)| (l.to_string(), *n)).collect()
    }

    // CK-BI-1: the estate over-weights philosophy and never touches finance;
    // against a balanced reference, philosophy is bias-for and finance is the
    // most-avoided bias-against. End-to-end over a real estate.
    #[test]
    fn ck_bi1_for_and_against_representation() {
        let (coord, h) = coord_with_parent();
        for _ in 0..4 {
            capture(&coord, &h, "philosophy");
        }
        capture(&coord, &h, "cooking");
        let reference = reference(&[("philosophy", 1.0), ("cooking", 1.0), ("finance", 1.0)]);

        let report = run_bias(&coord, &h, &reference, NOW).expect("bias");
        assert!(
            report.biased_for.iter().any(|b| b.label == "philosophy"),
            "over-weighted → for"
        );
        assert!(
            report.biased_against.iter().any(|b| b.label == "finance"),
            "never-captured → against"
        );
        // finance is the most-avoided (last by bias).
        assert_eq!(report.biased_against.last().unwrap().label, "finance");
    }

    // CK-BI-2: withdrawing memories from a room registers a dismissal rate —
    // "bias against" you enacted (the live withdraw verb makes this real today).
    #[test]
    fn ck_bi2_withdrawal_is_dismissal() {
        let (coord, h) = coord_with_parent();
        let r1 = capture(&coord, &h, "doubts");
        let _r2 = capture(&coord, &h, "doubts");
        capture(&coord, &h, "doubts");
        // Withdraw one of the "doubts" memories.
        coord
            .withdraw(&h, &r1, Some("reconsidered"), NOW)
            .expect("withdraw");

        let report = run_bias(&coord, &h, &reference(&[("doubts", 1.0)]), NOW).expect("bias");
        let doubts = report.dismissal.iter().find(|(room, _)| room == "doubts");
        assert!(doubts.is_some(), "the withdrawn room shows dismissal");
        assert!(
            doubts.unwrap().1 > 0.0,
            "dismissal rate is positive: {:?}",
            doubts
        );
    }

    // CK-BI-3: learned preference reads real curation choices end-to-end —
    // confirming a room's memories (the LIVE confirm verb) makes it preferred,
    // withdrawing another's makes it disfavored, and an untouched room sits at
    // neutral between them. This is the half the confirm verb unblocked.
    #[test]
    fn ck_bi3_confirm_and_withdraw_drive_learned_preference() {
        let (coord, h) = coord_with_parent();
        // "kept": captured then confirmed (endorsed).
        for _ in 0..3 {
            let id = capture(&coord, &h, "kept");
            coord
                .mutate(&h, &id, MutationKind::Confirm, None)
                .expect("confirm");
        }
        // "dropped": captured then withdrawn (dismissed).
        for _ in 0..3 {
            let id = capture(&coord, &h, "dropped");
            coord
                .withdraw(&h, &id, Some("reconsidered"), NOW)
                .expect("withdraw");
        }
        // "untouched": captured and left alone (no curation signal).
        capture(&coord, &h, "untouched");
        capture(&coord, &h, "untouched");

        let report = run_bias(&coord, &h, &reference(&[("kept", 1.0)]), NOW).expect("bias");
        let learned = &report.learned;

        // Endorsed leads, dismissed trails, neutral sits between.
        let order: Vec<&str> = learned.iter().map(|p| p.label.as_str()).collect();
        assert_eq!(
            order,
            vec!["kept", "untouched", "dropped"],
            "curation orders preference"
        );

        let kept = learned.iter().find(|p| p.label == "kept").unwrap();
        let dropped = learned.iter().find(|p| p.label == "dropped").unwrap();
        let untouched = learned.iter().find(|p| p.label == "untouched").unwrap();
        assert!(
            kept.strength > 0.0,
            "confirmed room preferred: {}",
            kept.strength
        );
        assert!(
            dropped.strength < 0.0,
            "withdrawn room disfavored: {}",
            dropped.strength
        );
        assert!(
            untouched.strength.abs() < 1e-6,
            "uncurated room neutral: {}",
            untouched.strength
        );
        // The raw curation counts round-tripped through the recall frames.
        assert_eq!(kept.endorsements, 3);
        assert_eq!(dropped.dismissals, 3);
    }
}
