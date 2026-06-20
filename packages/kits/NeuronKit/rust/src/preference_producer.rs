//! Preference PRODUCER support — the Rust mirror of Swift
//! `NeuronKit/Governor/PreferenceProducer.swift`.
//!
//! ─────────────────────────────────────────────────────────────────
//! DO NOT REIMPLEMENT SUBSTRATE MATH.
//!
//! The Bradley-Terry preference fit is the conformance-gated SubstrateML
//! primitive surfaced through NeuronKit's `Bias` lens (`learned_preference`, the
//! anchor-reduction fitter). This module is a CADENCE WRAPPER over that oracle:
//! it shapes the estate's recall-trace reward outcomes into per-drawer
//! (endorsements, dismissals) records, and the governor duty calls
//! `neuron_kit::learned_preference` and caches the per-drawer strengths. It owns
//! no fitting math (I-17).
//!
//! This is the SIBLING of graph_centrality.rs: same governor-duty shape, same
//! dark→live contract, different oracle and different input.
//! ─────────────────────────────────────────────────────────────────
//!
//! The cache + outcome builder here must compute the IDENTICAL records and
//! strengths as the Swift port (`PreferenceCache` / `PreferenceOutcomes`) so a
//! registered store reads the same `preference` column on both ports.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use genius_locus_kit::PreferenceStore;
use locus_kit::recall_trace_item::RecallTraceItem;

/// Pre-built per-drawer learned-preference cache for one estate.
///
/// Holds the Bradley-Terry preference strength for every drawer that appears in
/// the estate's recall-trace reward history, computed by the governor's
/// `preference_duty` on a cadence. Implements the GLK `recall::PreferenceStore`
/// consumption trait: the `matrixAware` / `unionBest` recall path reads
/// `preference_score(drawer_id)` per candidate drawer to populate the
/// `preference` score column. Drawers absent from the snapshot score 0.0, which
/// is correct (a drawer never surfaced in a recall has no learned preference —
/// neutral, identical to "no store registered").
///
/// Immutable after construction — the producer builds a fresh cache each cadence
/// and re-registers it, so a registered store never mutates under a concurrent
/// recall read. Mirrors Swift `PreferenceCache`.
pub struct PreferenceCache {
    /// drawer_id → Bradley-Terry preference strength (f32). Built once at
    /// construction.
    scores: HashMap<String, f32>,
}

impl PreferenceCache {
    /// Wrap a per-drawer preference snapshot.
    pub fn new(scores: HashMap<String, f32>) -> Self {
        Self { scores }
    }

    /// Number of drawers in the snapshot. Diagnostic accessor surfaced in the
    /// producer's tick log. Mirrors Swift `PreferenceCache.count`.
    pub fn count(&self) -> usize {
        self.scores.len()
    }
}

impl PreferenceStore for PreferenceCache {
    /// The preference score for `drawer_id`, or 0.0 when the drawer is not in the
    /// snapshot. A pure map lookup — no estate traversal, no synchronous model
    /// update, honouring the candidate-frontier-lookup-only contract (spec §15).
    /// Mirrors Swift `PreferenceCache.preference_score(for:)`.
    fn preference_score(&self, drawer_id: &str) -> f32 {
        self.scores.get(drawer_id).copied().unwrap_or(0.0)
    }
}

/// One per-drawer Bradley-Terry curation record. `endorsements` is the count of
/// recall traces where the drawer was surfaced AND picked (`used == true`);
/// `dismissals` is the count where it was surfaced but passed over
/// (`used == false`). The implicit relevance signal (C-15): what the user picked
/// vs ignored. Mirrors Swift `PreferenceOutcomes.Record`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreferenceRecord {
    pub label: String,
    pub endorsements: i64,
    pub dismissals: i64,
}

/// Build the per-drawer curation records from recall traces — the EXACT record
/// multiset the Swift `PreferenceOutcomes.build` produces, so both ports feed
/// `learned_preference` the same outcomes and obtain identical strengths.
///
/// One record per DISTINCT trace target (drawer id). A drawer surfaced N times
/// accrues N outcomes split into endorsements (used) and dismissals (not used).
/// Each appearance is one pairwise comparison against the neutral baseline in
/// the fitter's anchor reduction.
///
/// Determinism: records are returned sorted ascending by label (BTreeMap /
/// BTreeSet iteration) so the same trace set always yields the same record
/// sequence — matching the Swift port. `learned_preference` itself sorts its
/// output, but the INPUT order is fixed here so the two ports submit an
/// identical record vector. Grouping by target guarantees unique labels (the
/// fitter requirement).
pub fn preference_outcomes(traces: &[RecallTraceItem]) -> Vec<PreferenceRecord> {
    let mut endorsements: BTreeMap<&str, i64> = BTreeMap::new();
    let mut dismissals: BTreeMap<&str, i64> = BTreeMap::new();
    for trace in traces {
        if trace.used() {
            *endorsements.entry(trace.target.as_str()).or_insert(0) += 1;
        } else {
            *dismissals.entry(trace.target.as_str()).or_insert(0) += 1;
        }
    }
    // Distinct target set, sorted ascending for a deterministic record sequence.
    let mut labels: BTreeSet<&str> = BTreeSet::new();
    labels.extend(endorsements.keys().copied());
    labels.extend(dismissals.keys().copied());
    labels
        .into_iter()
        .map(|label| PreferenceRecord {
            label: label.to_string(),
            endorsements: endorsements.get(label).copied().unwrap_or(0),
            dismissals: dismissals.get(label).copied().unwrap_or(0),
        })
        .collect()
}

/// Run the Bradley-Terry fitter over the curation records and reduce to a
/// drawer_id → f32 strength map (the PreferenceStore payload). `learned_preference`
/// fits the gated BT utility via the anchor reduction and re-centres on the
/// neutral baseline. Empty records ⇒ empty result ⇒ empty map (C-16). The
/// `f64 → f32` narrowing is the documented float boundary the cross-port
/// conformance gate compares at.
///
/// Returns the fitter error only if a drawer id literally equals the baseline
/// sentinel — drawer ids are UUIDs, so this never arises in practice; the error
/// still propagates (the caller logs and the loop continues).
pub fn compute_preference_scores(
    records: &[PreferenceRecord],
) -> Result<HashMap<String, f32>, crate::TournamentError> {
    let tuples: Vec<(String, i64, i64)> = records
        .iter()
        .map(|r| (r.label.clone(), r.endorsements, r.dismissals))
        .collect();
    let strengths = crate::learned_preference(&tuples)?;
    let mut scores = HashMap::with_capacity(strengths.len());
    for strength in strengths {
        scores.insert(strength.label, strength.strength as f32);
    }
    Ok(scores)
}
