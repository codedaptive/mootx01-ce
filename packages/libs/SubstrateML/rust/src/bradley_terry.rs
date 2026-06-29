// bradley_terry.rs
//
// Bradley-Terry online preference learning per cookbook § 8.12.
//
// The Bradley-Terry model assigns each item a "strength" parameter
// w_i such that the probability that item i beats item j in a
// pairwise comparison is:
//
//   P(i beats j) = w_i / (w_i + w_j)
//
// The substrate uses BT to score ranking-relevant candidates over
// the long tail of RecallTrace feedback. Every time a CognitionKit
// primitive surfaces a candidate set and the user/agent selects
// one, the "used" candidate beats every "ignored" candidate in
// that decision instance. BT consumes those preferences online
// and produces a vector w_ranking[i] that weights how heavily the
// substrate trusts row i for future similar queries.
//
// CONSTITUTIONAL: w_ranking is a learned ranking signal, NOT a
// truth signal. It does not change which rows exist or what their
// fields say; it changes the ORDER in which candidates surface.
// Decay (cookbook § 6.8) prevents w_ranking from becoming
// dominated by ancient preferences.

use std::collections::HashMap;

// Phase 6.9c+lockstep audit: RowId comes from substrate-types,
// matching Swift's `public typealias RowId = UUID` per the
// Swift-leads 1:1 contract.
pub use substrate_types::RowId;

/// One preference observation from a RecallTrace. The `winner`
/// was selected by the user/agent; the `losers` were surfaced in
/// the same candidate set but ignored.
#[derive(Debug, Clone)]
pub struct PreferenceObservation {
    pub winner_id: RowId,
    pub losers: Vec<RowId>,
    pub weight: f64,         // typically 1.0 per RecallTrace
}

impl PreferenceObservation {
    pub fn new(winner_id: RowId, losers: Vec<RowId>) -> Self {
        Self { winner_id, losers, weight: 1.0 }
    }

    pub fn with_weight(winner_id: RowId, losers: Vec<RowId>, weight: f64) -> Self {
        Self { winner_id, losers, weight }
    }
}

/// Online Bradley-Terry estimator. Maintains the strength vector
/// `w[i]` indexed by row ID. Updates via stochastic gradient
/// ascent on the BT log-likelihood per observation.
///
/// For numerical stability we parameterize in log-space:
///   theta[i] = log(w[i])
///   P(i beats j) = sigmoid(theta[i] - theta[j])
///   gradient (winner i over loser j) = (1 - sigmoid(theta_i - theta_j))
///   update: theta_i += learning_rate * grad
///           theta_j -= learning_rate * grad
#[derive(Debug, Clone)]
pub struct BradleyTerryEstimator {
    /// Log-strength per row ID. Default 0.0 ⇒ strength 1.0.
    pub theta: HashMap<RowId, f64>,
    /// Learning rate. Cookbook § 8.12.3 recommends 0.05.
    pub learning_rate: f64,
    /// L2 regularization coefficient.
    pub l2: f64,
}

impl Default for BradleyTerryEstimator {
    fn default() -> Self {
        Self {
            theta: HashMap::new(),
            learning_rate: 0.05,
            l2: 0.001,
        }
    }
}

impl BradleyTerryEstimator {
    pub fn new(learning_rate: f64, l2: f64) -> Self {
        assert!(learning_rate > 0.0, "learning rate must be positive");
        assert!(l2 >= 0.0, "L2 must be non-negative");
        Self {
            theta: HashMap::new(),
            learning_rate,
            l2,
        }
    }

    /// Apply a single preference observation. Updates theta for
    /// the winner and all losers; cost is O(|losers|).
    pub fn observe(&mut self, obs: &PreferenceObservation) {
        let winner_theta = *self.theta.get(&obs.winner_id).unwrap_or(&0.0);
        // Apply winner and loser updates sequentially: each
        // iteration reuses the running winner_new value so
        // multiple losers in one observation produce the same
        // result as the Swift implementation's sequential update.
        let mut winner_new = winner_theta;
        let losers_clone = obs.losers.clone();
        for loser_id in losers_clone {
            let loser_theta = *self.theta.get(&loser_id).unwrap_or(&0.0);
            let p_winner_beats_loser = sigmoid(winner_new - loser_theta);
            let grad = obs.weight * (1.0 - p_winner_beats_loser);
            // Winner up; loser down. L2 regularization toward 0.
            winner_new = winner_new
                + self.learning_rate * grad
                - self.learning_rate * self.l2 * winner_new;
            let new_loser = loser_theta
                - self.learning_rate * grad
                - self.learning_rate * self.l2 * loser_theta;
            self.theta.insert(loser_id, new_loser);
        }
        self.theta.insert(obs.winner_id, winner_new);
    }

    /// Apply a batch of observations in order.
    pub fn observe_batch(&mut self, observations: &[PreferenceObservation]) {
        for obs in observations {
            self.observe(obs);
        }
    }

    /// Current strength `w[i] = exp(theta[i])`. Stronger ⇒
    /// surfaces higher in future ranked recalls.
    pub fn strength(&self, row_id: RowId) -> f64 {
        let t = *self.theta.get(&row_id).unwrap_or(&0.0);
        t.exp()
    }

    /// Probability that row `a` would beat row `b` in a pairwise
    /// preference, per the current model.
    pub fn probability_beats(&self, a: RowId, b: RowId) -> f64 {
        let ta = *self.theta.get(&a).unwrap_or(&0.0);
        let tb = *self.theta.get(&b).unwrap_or(&0.0);
        sigmoid(ta - tb)
    }
}

#[inline]
fn sigmoid(x: f64) -> f64 {
    1.0 / (1.0 + (-x).exp())
}

// Coupling to RecallTrace (cookbook § 11.18 + § 18.2)
//
// Every CognitionKit primitive emits a RecallTrace at completion
// with:
//
//   trace.query           — the query that produced the candidates
//   trace.candidates      — ordered list surfaced to user/agent
//   trace.used_row_id     — what they actually selected (None if abandoned)
//   trace.timestamp       — HLC at the time of decision
//
// The dreaming daemon (§ 15) batches RecallTraces and feeds them
// to BradleyTerryEstimator::observe_batch. The resulting
// w_ranking is written back to the row's calibration field
// (§ 6.6). Future recalls multiply candidate similarity by
// `strength(row_id)` to produce ranked output.
//
// Traces where used_row_id is None produce NO preference
// observation (no signal). Traces where the user explicitly
// clicked "none of these match" produce a negative observation
// for ALL candidates (all lose to a notional "absent" item with
// theta = 0). The dreaming daemon handles the "absent" case
// before calling observe().

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn winner_strength_increases() {
        let mut est = BradleyTerryEstimator::default();
        let s0 = est.strength(RowId(1));
        est.observe(&PreferenceObservation::new(RowId(1), vec![RowId(2), RowId(3)]));
        let s1 = est.strength(RowId(1));
        assert!(s1 > s0);
    }

    #[test]
    fn loser_strength_decreases() {
        let mut est = BradleyTerryEstimator::default();
        let s0 = est.strength(RowId(2));
        est.observe(&PreferenceObservation::new(RowId(1), vec![RowId(2)]));
        let s1 = est.strength(RowId(2));
        assert!(s1 < s0);
    }

    #[test]
    fn repeated_wins_converge() {
        let mut est = BradleyTerryEstimator::new(0.05, 0.0);
        for _ in 0..1000 {
            est.observe(&PreferenceObservation::new(RowId(1), vec![RowId(2)]));
        }
        let p = est.probability_beats(RowId(1), RowId(2));
        // With zero regularization and 1000 wins, P should be
        // close to 1.0.
        assert!(p > 0.9, "expected P(1 beats 2) > 0.9, got {p}");
    }

    #[test]
    fn unobserved_row_is_neutral() {
        let est = BradleyTerryEstimator::default();
        let s = est.strength(RowId(42));
        assert!((s - 1.0).abs() < 1e-9);
    }
}
