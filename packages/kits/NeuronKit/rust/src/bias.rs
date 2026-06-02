//! Preference lenses (SPEC § 7.3, Lens 4). `representation_bias` is the
//! DISTRIBUTIONAL half — a signed share difference, honest about being exactly
//! that. `learned_preference` is the LEARNED half — a Bradley-Terry utility
//! fitted from curation choices via the anchor reduction. Pure and
//! side-effect-free (I-18). `learned_preference` surfaces the gated
//! `bradley_terry` fitter; it owns no fitting math (I-17), only the anchor
//! construction and baseline re-centring.

use std::collections::BTreeSet;
use std::collections::HashMap;

use crate::tournament::{bradley_terry, PairwiseOutcome, TournamentError};

/// The reserved name for the shared neutral baseline competitor in the anchor
/// reduction. A curation record literally named this collides with the
/// synthetic baseline and surfaces as `TournamentError::SelfPairing`.
pub const PREFERENCE_BASELINE: &str = "PREFERENCE_BASELINE";

/// One category's representation bias: estate share, reference share, and the
/// signed difference. Positive = over-represented; negative = avoided.
#[derive(Clone, Debug, PartialEq)]
pub struct CategoryBias {
    pub label: String,
    pub estate_share: f64,
    pub reference_share: f64,
    pub bias: f64,
}

/// One room's learned preference strength on the Bradley-Terry log scale,
/// re-centred so the neutral baseline reads 0.
#[derive(Clone, Debug, PartialEq)]
pub struct PreferenceStrength {
    pub label: String,
    pub strength: f64,
    pub confidence_low: f64,
    pub confidence_high: f64,
    pub endorsements: i64,
    pub dismissals: i64,
}

/// Normalise `(label, mass)` pairs to shares summing to 1 (a side with no mass
/// yields an empty map ⇒ all shares 0).
fn shares(items: &[(String, f64)]) -> HashMap<String, f64> {
    let total: f64 = items.iter().map(|(_, m)| m).sum();
    if total <= 0.0 {
        return HashMap::new();
    }
    let mut out: HashMap<String, f64> = HashMap::new();
    for (label, mass) in items {
        *out.entry(label.clone()).or_insert(0.0) += mass / total;
    }
    out
}

/// Signed representation bias of `estate` against `reference`, per category over
/// the UNION of both label sets. A category present only in the reference gets
/// estate share 0 (strongly negative = avoided). Sorted by bias descending —
/// most over-represented first, most avoided last, ties by ascending label.
/// Both empty ⇒ empty (C-16).
pub fn representation_bias(
    estate: &[(String, f64)],
    reference: &[(String, f64)],
) -> Vec<CategoryBias> {
    let estate_shares = shares(estate);
    let reference_shares = shares(reference);

    let labels: BTreeSet<&String> = estate_shares
        .keys()
        .chain(reference_shares.keys())
        .collect();
    if labels.is_empty() {
        return Vec::new();
    }

    let mut out: Vec<CategoryBias> = labels
        .into_iter()
        .map(|label| {
            let e = *estate_shares.get(label).unwrap_or(&0.0);
            let r = *reference_shares.get(label).unwrap_or(&0.0);
            CategoryBias {
                label: label.clone(),
                estate_share: e,
                reference_share: r,
                bias: e - r,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.bias
            .partial_cmp(&a.bias)
            .unwrap_or(std::cmp::Ordering::Equal) // descending bias
            .then_with(|| a.label.cmp(&b.label)) // ties: ascending label
    });
    out
}

/// Fit a Bradley-Terry preference over rooms from per-room curation records
/// `(label, endorsements, dismissals)`, re-centred on a neutral baseline and
/// returned strongest first (ties by ascending label). Empty input ⇒ empty.
///
/// The anchor reduction: every room competes against one shared neutral
/// baseline, beating it once per endorsement and losing once per dismissal,
/// with a uniform +1 pseudo-win added in EACH direction between every room and
/// the baseline. That symmetric prior makes the directed win graph strongly
/// connected — so the fit is finite even for a one-sided room and
/// `DisconnectedComparisonGraph` cannot arise — and shrinks little-curated
/// rooms toward the baseline. The baseline's fitted strength is subtracted from
/// every room so the baseline reads exactly 0.
///
/// Returns `Err(TournamentError::SelfPairing)` only if a room is literally
/// named the baseline sentinel.
pub fn learned_preference(
    records: &[(String, i64, i64)],
) -> Result<Vec<PreferenceStrength>, TournamentError> {
    if records.is_empty() {
        return Ok(Vec::new());
    }

    // Build the anchor-reduction tally. Each room vs the baseline:
    //   +1 pseudo-win each direction, +endorsements room-beats-baseline,
    //   +dismissals baseline-beats-room.
    let mut outcomes: Vec<PairwiseOutcome> = Vec::with_capacity(records.len() * 2);
    for (label, endorsements, dismissals) in records {
        if label == PREFERENCE_BASELINE {
            return Err(TournamentError::SelfPairing(
                PREFERENCE_BASELINE.to_string(),
            ));
        }
        outcomes.push(PairwiseOutcome::new(
            label,
            PREFERENCE_BASELINE,
            endorsements + 1,
        ));
        outcomes.push(PairwiseOutcome::new(
            PREFERENCE_BASELINE,
            label,
            dismissals + 1,
        ));
    }

    // Surface the gated fitter (I-17).
    let fitted = bradley_terry(&outcomes)?;

    // Re-centre on the baseline's fitted strength.
    let baseline_strength = fitted
        .iter()
        .find(|s| s.competitor_id == PREFERENCE_BASELINE)
        .map(|s| s.strength)
        .unwrap_or(0.0);
    let counts: HashMap<&str, (i64, i64)> = records
        .iter()
        .map(|(l, e, d)| (l.as_str(), (*e, *d)))
        .collect();

    let mut rooms: Vec<PreferenceStrength> = fitted
        .iter()
        .filter(|s| s.competitor_id != PREFERENCE_BASELINE)
        .map(|s| {
            let (endorsements, dismissals) =
                *counts.get(s.competitor_id.as_str()).unwrap_or(&(0, 0));
            PreferenceStrength {
                label: s.competitor_id.clone(),
                strength: s.strength - baseline_strength,
                confidence_low: s.confidence_low - baseline_strength,
                confidence_high: s.confidence_high - baseline_strength,
                endorsements,
                dismissals,
            }
        })
        .collect();
    rooms.sort_by(|a, b| {
        b.strength
            .partial_cmp(&a.strength)
            .unwrap_or(std::cmp::Ordering::Equal) // descending strength
            .then_with(|| a.label.cmp(&b.label)) // ties: ascending label
    });
    Ok(rooms)
}

#[cfg(test)]
mod tests {
    // Tests assert SPEC § 7.3's claims about the preference lenses:
    // representation_bias is a signed share difference; learned_preference fits
    // a BT utility via the anchor reduction (one-sided rooms still fit, sparse
    // signal shrinks to neutral), is deterministic, total on empty input, and
    // throws SelfPairing only on the baseline sentinel name (§ 6).
    use super::*;

    fn masses(xs: &[(&str, f64)]) -> Vec<(String, f64)> {
        xs.iter().map(|(l, m)| (l.to_string(), *m)).collect()
    }
    fn records(xs: &[(&str, i64, i64)]) -> Vec<(String, i64, i64)> {
        xs.iter().map(|(l, e, d)| (l.to_string(), *e, *d)).collect()
    }

    #[test]
    fn bias_is_signed_share_difference() {
        let estate = masses(&[("work", 10.0)]);
        let reference = masses(&[("work", 5.0), ("play", 5.0)]);
        let bias = representation_bias(&estate, &reference);
        let work = bias.iter().find(|b| b.label == "work").unwrap();
        let play = bias.iter().find(|b| b.label == "play").unwrap();
        assert!((work.bias - 0.5).abs() < 1e-9);
        assert!((play.bias + 0.5).abs() < 1e-9, "avoided category negative");
        assert!((work.estate_share - 1.0).abs() < 1e-9);
        assert!(play.estate_share.abs() < 1e-9);
    }

    #[test]
    fn bias_sorted_descending_ties_by_label() {
        let estate = masses(&[("a", 1.0), ("b", 1.0), ("hot", 8.0)]);
        let reference = masses(&[("a", 1.0), ("b", 1.0), ("hot", 1.0)]);
        let bias = representation_bias(&estate, &reference);
        assert_eq!(bias[0].label, "hot");
        for pair in bias.windows(2) {
            assert!(pair[0].bias >= pair[1].bias);
        }
        let ai = bias.iter().position(|b| b.label == "a").unwrap();
        let bi = bias.iter().position(|b| b.label == "b").unwrap();
        assert!(ai < bi, "ties ascending label");
    }

    #[test]
    fn bias_total_over_edge_inputs() {
        assert!(representation_bias(&[], &[]).is_empty());
    }

    #[test]
    fn endorsed_rooms_outrank_dismissed() {
        let r = records(&[("loved", 8, 1), ("mixed", 3, 3), ("disliked", 1, 8)]);
        let prefs = learned_preference(&r).unwrap();
        let loved = prefs.iter().find(|p| p.label == "loved").unwrap();
        let mixed = prefs.iter().find(|p| p.label == "mixed").unwrap();
        let disliked = prefs.iter().find(|p| p.label == "disliked").unwrap();
        assert!(loved.strength > 0.0);
        assert!(disliked.strength < 0.0);
        assert!(mixed.strength.abs() < loved.strength);
        assert_eq!(prefs[0].label, "loved");
        assert_eq!((loved.endorsements, loved.dismissals), (8, 1));
    }

    #[test]
    fn one_sided_rooms_still_fit() {
        let r = records(&[("alwaysKept", 5, 0), ("alwaysTossed", 0, 5)]);
        let prefs = learned_preference(&r).unwrap();
        assert_eq!(prefs.len(), 2);
        let kept = prefs
            .iter()
            .find(|p| p.label == "alwaysKept")
            .unwrap()
            .strength;
        let tossed = prefs
            .iter()
            .find(|p| p.label == "alwaysTossed")
            .unwrap()
            .strength;
        assert!(kept > tossed);
    }

    #[test]
    fn sparse_signal_shrinks_to_neutral() {
        let r = records(&[("barelyTouched", 1, 1), ("stronglyLoved", 20, 0)]);
        let prefs = learned_preference(&r).unwrap();
        let barely = prefs.iter().find(|p| p.label == "barelyTouched").unwrap();
        assert!(
            barely.strength.abs() < 0.5,
            "near neutral with little signal"
        );
    }

    #[test]
    fn deterministic() {
        let r = records(&[("x", 4, 2), ("y", 2, 4)]);
        assert_eq!(learned_preference(&r), learned_preference(&r));
    }

    #[test]
    fn empty_input_empty_output() {
        assert!(learned_preference(&[]).unwrap().is_empty());
    }

    #[test]
    fn baseline_sentinel_name_errors() {
        let r = records(&[(PREFERENCE_BASELINE, 3, 1)]);
        assert_eq!(
            learned_preference(&r),
            Err(TournamentError::SelfPairing(
                PREFERENCE_BASELINE.to_string()
            ))
        );
    }
}
