//! Anticipation — the learned action→outcome model (SPEC § 7.4, Lens 4
//! Prediction). Given observed action→outcome events, learn which actions
//! reliably reach a desired target outcome, ranked by the Wilson lower bound so
//! a few lucky successes don't outrank a well-evidenced action. "To reach Y,
//! you tend to do X." Surfaces SubstrateML's ActionOutcomeMatrix + Wilson
//! bound; owns no math (I-17). Pure and total (I-18, B-8).

use substrate_ml::action_outcome::ActionOutcomeMatrix;
use substrate_types::hlc::HLC;

/// One observed action→outcome event. `success` records whether the action
/// achieved its intended result on that occasion.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ActionObservation {
    pub action: u8,
    pub outcome: u8,
    pub success: bool,
}

/// One predicted action for a target outcome: its Wilson-lower-bound success
/// rate (the ranking key) and the total observations behind it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ActionPrediction {
    pub action: u8,
    pub success_rate: f32, // Wilson lower bound, ranked descending
    pub count: u32,
}

/// Rank the actions that reach `target_outcome`, learned from `observations`, by
/// Wilson lower bound (descending) — returning the top `k` actions seen at least
/// `min_observations` times. Events are category-keyed, so HLC ordering is
/// irrelevant: every observation is recorded at `HLC::zero()` (recency is a
/// separate concern — theme weather). No observations or `k == 0` ⇒ empty
/// (C-16).
pub fn anticipate(
    observations: &[ActionObservation],
    target_outcome: u8,
    k: usize,
    min_observations: u32,
) -> Vec<ActionPrediction> {
    if observations.is_empty() || k == 0 {
        return Vec::new();
    }

    // Shape the events into the gated matrix. HLC is irrelevant here, so every
    // observation lands at zero (I-17: the matrix owns the math).
    let mut matrix = ActionOutcomeMatrix::new();
    for o in observations {
        matrix.observe(o.action, o.outcome, o.success, HLC::zero());
    }

    // Read the cells for the target outcome, keeping those seen at least
    // min_observations times. success_rate carries the Wilson lower bound — the
    // same conservative signal the ranking uses (INTERFACE § 2). The matrix
    // computes the bound per cell (I-17); the lens does not.
    let mut candidates: Vec<ActionPrediction> = matrix
        .cells
        .iter()
        .filter(|(key, cell)| {
            key.outcome_category == target_outcome && cell.total_count >= min_observations
        })
        .map(|(key, cell)| ActionPrediction {
            action: key.action_kind,
            success_rate: cell.wilson_lower_bound(),
            count: cell.total_count,
        })
        .collect();

    // Rank by Wilson lower bound descending; ties by count descending, then
    // action ascending (the primitive's documented tie-break — C-17). Cap to k.
    candidates.sort_by(|a, b| {
        b.success_rate
            .partial_cmp(&a.success_rate)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.count.cmp(&a.count))
            .then_with(|| a.action.cmp(&b.action))
    });
    candidates.truncate(k);
    candidates
}

#[cfg(test)]
mod tests {
    // Tests assert SPEC § 7.4's claims about anticipation: a well-evidenced
    // action outranks a lucky thin one (Wilson ranking), below-threshold and
    // other-outcome actions are excluded, the result is capped to k, count
    // reflects total observations, the lens is deterministic, and it is total
    // over edge inputs.
    use super::*;

    fn obs(action: u8, outcome: u8, success: bool, n: usize) -> Vec<ActionObservation> {
        (0..n)
            .map(|_| ActionObservation {
                action,
                outcome,
                success,
            })
            .collect()
    }

    #[test]
    fn well_evidenced_action_outranks_lucky_thin_one() {
        let target = 1u8;
        let mut events = Vec::new();
        events.extend(obs(1, target, true, 18));
        events.extend(obs(1, target, false, 2)); // 18/20
        events.extend(obs(2, target, true, 2)); // 2/2, thin
        let preds = anticipate(&events, target, 10, 1);
        assert_eq!(
            preds[0].action, 1,
            "well-evidenced action ranks first by Wilson LB"
        );
        for pair in preds.windows(2) {
            assert!(
                pair[0].success_rate >= pair[1].success_rate,
                "descending Wilson LB"
            );
        }
    }

    #[test]
    fn filters_below_min_observations() {
        let target = 1u8;
        let mut events = Vec::new();
        events.extend(obs(1, target, true, 10));
        events.extend(obs(2, target, true, 2));
        let preds = anticipate(&events, target, 10, 5);
        assert!(preds.iter().any(|p| p.action == 1));
        assert!(
            !preds.iter().any(|p| p.action == 2),
            "below-threshold filtered"
        );
    }

    #[test]
    fn ignores_other_outcomes() {
        let mut events = Vec::new();
        events.extend(obs(1, 1, true, 10));
        events.extend(obs(2, 2, true, 10));
        let preds = anticipate(&events, 1, 10, 1);
        assert!(preds.iter().any(|p| p.action == 1));
        assert!(
            !preds.iter().any(|p| p.action == 2),
            "other-outcome action not predicted"
        );
    }

    #[test]
    fn capped_to_k() {
        let target = 1u8;
        let mut events = Vec::new();
        for a in 1..=5u8 {
            events.extend(obs(a, target, true, 10));
        }
        assert_eq!(anticipate(&events, target, 3, 1).len(), 3);
    }

    #[test]
    fn count_reflects_total_observations() {
        let target = 1u8;
        let mut events = Vec::new();
        events.extend(obs(1, target, true, 7));
        events.extend(obs(1, target, false, 3)); // 10 total
        let preds = anticipate(&events, target, 10, 1);
        assert_eq!(preds.iter().find(|p| p.action == 1).unwrap().count, 10);
    }

    #[test]
    fn deterministic() {
        let target = 1u8;
        let mut events = Vec::new();
        events.extend(obs(1, target, true, 8));
        events.extend(obs(2, target, true, 5));
        events.extend(obs(1, target, false, 2));
        assert_eq!(
            anticipate(&events, target, 10, 1),
            anticipate(&events, target, 10, 1)
        );
    }

    #[test]
    fn total_over_edge_inputs() {
        assert!(anticipate(&[], 1, 10, 1).is_empty());
        let events = obs(1, 1, true, 5);
        assert!(anticipate(&events, 1, 0, 1).is_empty());
    }
}
