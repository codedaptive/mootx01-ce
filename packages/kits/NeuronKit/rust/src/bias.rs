//! Bias — over/under-representation against a reference (Lens 4, Preference &
//! judgment): the NeuronKit reasoning surface for "what the estate leans
//! toward vs away from." Per category, the signed difference between the
//! estate's share and a reference share — positive = bias FOR (over-
//! represented), negative = bias AGAINST (under-represented, or avoided
//! entirely when the estate's share is zero).
//!
//! This is the DISTRIBUTIONAL half of the preference lens — what the corpus
//! over- and under-weights — and is honest about being a share difference, not
//! dressed-up math. `learned_preference` (below) is the deeper, LEARNED half:
//! a Bradley-Terry utility fitted from actual curation choices (confirmations
//! and withdrawals), now that the `confirm` verb makes those choices a real
//! event source. The estate-side recipe also reports a dismissal signal
//! (withdrawal rates) for "bias against".

/// One category's representation bias. `bias = estate_share - reference_share`.
#[derive(Clone, Debug, PartialEq)]
pub struct CategoryBias {
    pub label: String,
    pub estate_share: f64,
    pub reference_share: f64,
    /// Signed: > 0 over-represented (for), < 0 under-represented (against).
    pub bias: f64,
}

fn normalize(counts: &[(String, f64)]) -> std::collections::BTreeMap<String, f64> {
    let total: f64 = counts.iter().map(|(_, c)| c).sum();
    let mut out = std::collections::BTreeMap::new();
    if total <= 0.0 {
        return out;
    }
    for (label, c) in counts {
        *out.entry(label.clone()).or_insert(0.0) += c / total;
    }
    out
}

/// Signed representation bias of `estate` against `reference`, per category
/// over the UNION of both label sets (a category present only in the reference
/// gets estate_share 0 ⇒ strongly negative = avoided). Sorted by bias
/// descending — most over-represented first, most avoided last. Ties by label.
pub fn representation_bias(
    estate: &[(String, f64)],
    reference: &[(String, f64)],
) -> Vec<CategoryBias> {
    let e = normalize(estate);
    let r = normalize(reference);
    let mut labels: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for k in e.keys().chain(r.keys()) {
        labels.insert(k.clone());
    }
    let mut out: Vec<CategoryBias> = labels
        .into_iter()
        .map(|label| {
            let estate_share = e.get(&label).copied().unwrap_or(0.0);
            let reference_share = r.get(&label).copied().unwrap_or(0.0);
            CategoryBias { label, estate_share, reference_share, bias: estate_share - reference_share }
        })
        .collect();
    out.sort_by(|a, b| {
        b.bias.partial_cmp(&a.bias).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.label.cmp(&b.label))
    });
    out
}

// ============================================================
// Learned preference (Bradley-Terry over curation choices)
// ============================================================

use crate::tournament::{bradley_terry, BradleyTerryScore, PairwiseOutcome, TournamentError};

/// The neutral reference competitor every room is compared against in the
/// anchor reduction. NUL-prefixed so it cannot collide with a real room name;
/// a record carrying this exact label is a caller error (it would self-pair
/// against the anchor, surfaced as `TournamentError::SelfPairing`).
const PREFERENCE_BASELINE: &str = "\u{0}__preference_baseline__";

/// One room's learned-preference strength: the Bradley-Terry latent utility
/// inferred from CURATION outcomes — confirmations (endorsements) as wins,
/// withdrawals (dismissals) as losses — re-centered on the neutral baseline so
/// `strength > 0` means preferred over neutral and `< 0` means disfavored.
///
/// Distinct from `CategoryBias`: that counts capture VOLUME; this measures
/// preference REVEALED BY CURATION. A room captured heavily but never confirmed
/// (or often withdrawn) ranks LOW here while ranking high in representation —
/// exactly the signal "what you actually keep vs what merely accumulates."
#[derive(Clone, Debug, PartialEq)]
pub struct PreferenceStrength {
    pub label: String,
    /// BT log-strength, re-centered on the baseline (baseline reads as 0).
    pub strength: f64,
    pub confidence_low: f64,
    pub confidence_high: f64,
    pub endorsements: i64,
    pub dismissals: i64,
}

/// Fit a Bradley-Terry preference over rooms from per-room curation records
/// `(label, endorsements, dismissals)`, re-centered on a neutral baseline and
/// returned strongest first (ties by ascending label). Labels must be unique.
///
/// Construction — the ANCHOR reduction: every room competes against ONE shared
/// neutral baseline competitor; it beats the baseline once per endorsement
/// (confirmation) and loses to it once per dismissal (withdrawal). A uniform
/// +1 pseudo-win is added in EACH direction between every room and the
/// baseline. That minimal symmetric prior does two things:
///   1. it makes the directed win graph strongly connected (every room has
///      both an in- and an out-edge to the baseline regardless of the data),
///      so the BT MLE is finite even for an only-confirmed or only-withdrawn
///      room — i.e. it cannot raise `DisconnectedComparisonGraph`; and
///   2. it shrinks rooms with little or no curation signal toward the baseline
///      (strength ≈ 0 = "no learned preference yet").
///
/// The fitter gauge-fixes strengths to sum to zero over {rooms, baseline};
/// re-centering subtracts the baseline's fitted strength so the baseline reads
/// as exactly 0 and each room's sign is its preference relative to neutral.
/// Empty input ⇒ empty output. Propagates `SelfPairing` only if a room is
/// literally named `PREFERENCE_BASELINE`.
pub fn learned_preference(
    records: &[(String, i64, i64)],
) -> Result<Vec<PreferenceStrength>, TournamentError> {
    if records.is_empty() {
        return Ok(Vec::new());
    }

    let mut outcomes: Vec<PairwiseOutcome> = Vec::with_capacity(records.len() * 2);
    for (label, endorsements, dismissals) in records {
        // +1 uniform prior in each direction → strong connectivity + shrinkage.
        let wins = (*endorsements).max(0) + 1; // room beats baseline (endorsed)
        let losses = (*dismissals).max(0) + 1; // baseline beats room (dismissed)
        outcomes.push(PairwiseOutcome::new(label, PREFERENCE_BASELINE, wins));
        outcomes.push(PairwiseOutcome::new(PREFERENCE_BASELINE, label, losses));
    }

    let scores = bradley_terry(&outcomes)?;
    let baseline_strength = scores
        .iter()
        .find(|s| s.competitor_id == PREFERENCE_BASELINE)
        .map(|s| s.strength)
        .unwrap_or(0.0);
    let by_label: std::collections::BTreeMap<&str, &BradleyTerryScore> =
        scores.iter().map(|s| (s.competitor_id.as_str(), s)).collect();

    let mut out: Vec<PreferenceStrength> = records
        .iter()
        .map(|(label, endorsements, dismissals)| {
            let (strength, lo, hi) = by_label
                .get(label.as_str())
                .map(|s| (s.strength, s.confidence_low, s.confidence_high))
                .unwrap_or((0.0, 0.0, 0.0));
            PreferenceStrength {
                label: label.clone(),
                strength: strength - baseline_strength,
                confidence_low: lo - baseline_strength,
                confidence_high: hi - baseline_strength,
                endorsements: *endorsements,
                dismissals: *dismissals,
            }
        })
        .collect();
    out.sort_by(|a, b| {
        b.strength
            .partial_cmp(&a.strength)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.label.cmp(&b.label))
    });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(pairs: &[(&str, f64)]) -> Vec<(String, f64)> {
        pairs.iter().map(|(l, n)| (l.to_string(), *n)).collect()
    }
    fn bias_of(v: &[CategoryBias], label: &str) -> f64 {
        v.iter().find(|b| b.label == label).unwrap().bias
    }
    fn rec(triples: &[(&str, i64, i64)]) -> Vec<(String, i64, i64)> {
        triples.iter().map(|(l, e, d)| (l.to_string(), *e, *d)).collect()
    }
    fn pref_of<'a>(v: &'a [PreferenceStrength], label: &str) -> &'a PreferenceStrength {
        v.iter().find(|p| p.label == label).unwrap()
    }

    // BI-1: a category the estate over-weights relative to the reference is
    // bias FOR (positive, ranked first); one it under-weights is AGAINST.
    #[test]
    fn bi1_over_and_under_representation() {
        // Estate is 80% philosophy, 20% cooking; reference is 50/50.
        let estate = c(&[("philosophy", 8.0), ("cooking", 2.0)]);
        let reference = c(&[("philosophy", 5.0), ("cooking", 5.0)]);
        let b = representation_bias(&estate, &reference);
        assert_eq!(b[0].label, "philosophy", "the over-weighted category leads");
        assert!(bias_of(&b, "philosophy") > 0.0, "bias FOR");
        assert!(bias_of(&b, "cooking") < 0.0, "bias AGAINST");
    }

    // BI-2: a category present in the reference but ABSENT from the estate is
    // strongly biased-against (avoided) — estate_share 0, full negative.
    #[test]
    fn bi2_avoided_category_is_against() {
        let estate = c(&[("philosophy", 10.0)]);
        let reference = c(&[("philosophy", 5.0), ("finance", 5.0)]);
        let b = representation_bias(&estate, &reference);
        let finance = b.iter().find(|x| x.label == "finance").unwrap();
        assert_eq!(finance.estate_share, 0.0, "never captured");
        assert!(finance.bias < 0.0, "an avoided topic is biased against");
        assert!(b.last().unwrap().label == "finance", "the most-avoided is last");
    }

    // BI-3: an estate matching the reference has ~zero bias everywhere.
    #[test]
    fn bi3_matching_reference_is_unbiased() {
        let estate = c(&[("a", 3.0), ("b", 3.0)]);
        let reference = c(&[("a", 1.0), ("b", 1.0)]);
        let b = representation_bias(&estate, &reference);
        assert!(b.iter().all(|x| x.bias.abs() < 1e-9), "balanced ⇒ unbiased");
    }

    // LP-1: a confirmed-heavy room outranks a withdrawn-heavy one; the endorsed
    // room is preferred over neutral (> 0), the dismissed room disfavored (< 0).
    #[test]
    fn lp1_confirmed_outranks_withdrawn() {
        let r = rec(&[("kept", 5, 0), ("dropped", 0, 5)]);
        let p = learned_preference(&r).expect("finite fit (prior guarantees connectivity)");
        assert_eq!(p[0].label, "kept", "the endorsed room leads");
        assert!(pref_of(&p, "kept").strength > 0.0, "endorsed ⇒ preferred over neutral");
        assert!(pref_of(&p, "dropped").strength < 0.0, "withdrawn ⇒ disfavored");
    }

    // LP-2: a room with no curation signal sits at the neutral baseline (≈ 0),
    // between an endorsed and a dismissed room — "no learned preference yet."
    #[test]
    fn lp2_uncurated_room_is_neutral() {
        let r = rec(&[("kept", 6, 0), ("untouched", 0, 0), ("dropped", 0, 6)]);
        let p = learned_preference(&r).expect("finite fit");
        let order: Vec<&str> = p.iter().map(|x| x.label.as_str()).collect();
        assert_eq!(order, vec!["kept", "untouched", "dropped"], "endorsed > neutral > dismissed");
        // ≈ 0 to the fitter's documented log-strength tolerance (the 1-1 record
        // against the baseline puts it exactly at neutral at the MLE).
        assert!(pref_of(&p, "untouched").strength.abs() < 1e-6, "no curation ⇒ ≈ baseline");
    }

    // LP-3: the +1 prior keeps the fit finite even when EVERY room is
    // only-confirmed (no withdrawals anywhere) — the construction can never
    // raise DisconnectedComparisonGraph.
    #[test]
    fn lp3_all_only_confirmed_still_finite() {
        let r = rec(&[("a", 3, 0), ("b", 7, 0), ("c", 1, 0)]);
        let p = learned_preference(&r).expect("prior keeps the win graph strongly connected");
        // More endorsements ⇒ stronger; all preferred over neutral.
        assert_eq!(p[0].label, "b", "the most-confirmed room leads");
        assert!(p.iter().all(|x| x.strength > 0.0), "every confirmed room is preferred");
    }

    // LP-4: empty input ⇒ empty output (guarded).
    #[test]
    fn lp4_empty_is_empty() {
        assert!(learned_preference(&[]).expect("empty ok").is_empty());
    }
}
