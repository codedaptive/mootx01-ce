//! Anticipation — the learned action→outcome model (Lens 8, Prediction): the
//! NeuronKit reasoning surface over SubstrateML's `ActionOutcomeMatrix`. Given
//! observed (action, outcome, success) events, learn which actions reliably
//! reach a desired outcome — ranked by the Wilson lower bound, so a few lucky
//! successes don't outrank a well-evidenced action. "To reach Y, you tend to
//! do X." This is the genuine action-outcome lens (not the explicit-tunnel
//! successor signal in `tunnel_successor_recipe`).
//!
//! Layer B-1: the matrix + Wilson math live in SubstrateML; this shapes
//! observations into the matrix and the matrix into predictions. CognitionKit
//! sequences it (derive the events from the estate, then call this).

use substrate_ml::action_outcome::ActionOutcomeMatrix;
use substrate_types::hlc::HLC;

/// One observed event: taking `action` (a category u8) produced `outcome` (a
/// category u8), and whether that counted as a success.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ActionObservation {
    pub action: u8,
    pub outcome: u8,
    pub success: bool,
}

/// A predicted action for a target outcome: its observed success rate and how
/// many times it was seen. Returned ranked by the matrix's Wilson lower bound
/// (well-evidenced actions first).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ActionPrediction {
    pub action: u8,
    pub success_rate: f32,
    pub count: u32,
}

/// Learn from `observations` and return the top `k` actions most reliably
/// reaching `target_outcome` (at least `min_observations` seen). The events
/// are category-keyed, so HLC ordering is irrelevant here — `HLC::zero()` is
/// used for every observation (recency/decay is a separate concern).
pub fn anticipate(
    observations: &[ActionObservation],
    target_outcome: u8,
    k: usize,
    min_observations: u32,
) -> Vec<ActionPrediction> {
    let mut matrix = ActionOutcomeMatrix::new();
    for o in observations {
        matrix.observe(o.action, o.outcome, o.success, HLC::zero());
    }
    matrix
        .top_actions(target_outcome, k, min_observations)
        .into_iter()
        .map(|(action, success_rate, count)| ActionPrediction { action, success_rate, count })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(action: u8, outcome: u8, success: bool, n: usize) -> Vec<ActionObservation> {
        (0..n).map(|_| ActionObservation { action, outcome, success }).collect()
    }

    // AC-1: for a target outcome, the action with the stronger evidenced
    // success rate ranks first. Action 1 succeeds 4/4 toward outcome 9;
    // action 2 succeeds 1/4. top action for outcome 9 is action 1.
    #[test]
    fn ac1_better_action_ranks_first() {
        let mut events = obs(1, 9, true, 4);
        events.extend(obs(2, 9, true, 1));
        events.extend(obs(2, 9, false, 3));
        let pred = anticipate(&events, 9, 5, 1);
        assert!(!pred.is_empty());
        assert_eq!(pred[0].action, 1, "the reliably-successful action leads");
        assert!(pred[0].success_rate > 0.9);
    }

    // AC-2: min_observations filters out under-evidenced actions — an action
    // seen only once is excluded at min 2.
    #[test]
    fn ac2_min_observations_filters() {
        let mut events = obs(1, 9, true, 5);
        events.extend(obs(3, 9, true, 1)); // only once
        let pred = anticipate(&events, 9, 5, 2);
        assert!(pred.iter().all(|p| p.action != 3), "under-evidenced action excluded");
        assert!(pred.iter().any(|p| p.action == 1));
    }

    // AC-3: an outcome never observed yields no predictions (guarded).
    #[test]
    fn ac3_unseen_outcome_empty() {
        let events = obs(1, 9, true, 3);
        assert!(anticipate(&events, 200, 5, 1).is_empty());
    }
}
