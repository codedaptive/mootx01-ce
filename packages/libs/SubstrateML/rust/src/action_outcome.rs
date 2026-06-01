// action_outcome.rs
//
// Action-outcome matrix per cookbook § 6.5. Mirror of
// glref-swift-ActionOutcomeMatrix.swift.

use std::collections::HashMap;
use substrate_types::hlc::HLC;

/// Composite key (action_kind, outcome_category) into the matrix.
/// Both fields fit in 6 bits per bitmap-tier invariant I-6.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ActionOutcomeKey {
    pub action_kind: u8,
    pub outcome_category: u8,
}

impl ActionOutcomeKey {
    pub fn new(action_kind: u8, outcome_category: u8) -> Self {
        assert!(action_kind < 64, "action_kind must fit in 6 bits (bitmap o07)");
        assert!(outcome_category < 64, "outcome_category must fit in 6 bits (bitmap o08)");
        Self { action_kind, outcome_category }
    }

    pub fn packed(&self) -> u16 {
        ((self.action_kind as u16) << 8) | (self.outcome_category as u16)
    }
}

impl Ord for ActionOutcomeKey {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.packed().cmp(&other.packed())
    }
}

impl PartialOrd for ActionOutcomeKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ActionOutcomeCell {
    pub success_count: u32,
    pub total_count: u32,
    pub last_update_hlc: HLC,
}

impl ActionOutcomeCell {
    pub fn new(last_update_hlc: HLC) -> Self {
        Self { success_count: 0, total_count: 0, last_update_hlc }
    }

    pub fn success_rate(&self) -> f32 {
        if self.total_count == 0 { 0.0 } else {
            self.success_count as f32 / self.total_count as f32
        }
    }

    /// Wilson lower bound (95% confidence) for ranking sparse cells.
    pub fn wilson_lower_bound(&self) -> f32 {
        if self.total_count == 0 { return 0.0; }
        let n = self.total_count as f32;
        let phat = self.success_rate();
        let z: f32 = 1.96;
        let denom = 1.0 + (z * z) / n;
        let centre = phat + (z * z) / (2.0 * n);
        let margin = z * (phat * (1.0 - phat) / n + (z * z) / (4.0 * n * n)).sqrt();
        (centre - margin) / denom
    }
}

#[derive(Debug, Clone, Default)]
pub struct ActionOutcomeMatrix {
    pub cells: HashMap<ActionOutcomeKey, ActionOutcomeCell>,
}

impl ActionOutcomeMatrix {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(&mut self, action: u8, outcome: u8, success: bool, hlc: HLC) {
        let key = ActionOutcomeKey::new(action, outcome);
        let cell = self.cells
            .entry(key)
            .or_insert(ActionOutcomeCell::new(hlc));
        cell.total_count = cell.total_count.wrapping_add(1);
        if success {
            cell.success_count = cell.success_count.wrapping_add(1);
        }
        cell.last_update_hlc = hlc;
    }

    pub fn success_rate(&self, action: u8, outcome: u8) -> Option<f32> {
        let key = ActionOutcomeKey::new(action, outcome);
        self.cells
            .get(&key)
            .filter(|c| c.total_count > 0)
            .map(|c| c.success_rate())
    }

    pub fn observation_count(&self, action: u8, outcome: u8) -> u32 {
        let key = ActionOutcomeKey::new(action, outcome);
        self.cells.get(&key).map(|c| c.total_count).unwrap_or(0)
    }

    /// Best actions for the given outcome, ranked by Wilson lower
    /// bound. Ties broken by total count desc, then action asc.
    ///
    /// Returns `(action_kind, success_rate, wilson_lower_bound, total_count)`.
    /// The wilson_lower_bound is the value used for ranking; surfacing it
    /// prevents an order/value mismatch where results are ordered by Wilson
    /// LB but callers only see the raw success_rate. Mirrors the Swift leg's
    /// return shape exactly (cookbook conformance contract).
    pub fn top_actions(&self, outcome: u8, k: usize, min_observations: u32)
                       -> Vec<(u8, f32, f32, u32)> {
        let mut filtered: Vec<(u8, f32, f32, u32)> = self.cells.iter()
            .filter(|(k, c)| k.outcome_category == outcome && c.total_count >= min_observations)
            .map(|(k, c)| (k.action_kind, c.success_rate(), c.wilson_lower_bound(), c.total_count))
            .collect();
        filtered.sort_by(|a, b| {
            b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal)
                .then(b.3.cmp(&a.3))
                .then(a.0.cmp(&b.0))
        });
        filtered.into_iter()
            .take(k)
            .collect()
    }

    pub fn populated_cell_count(&self) -> usize {
        self.cells.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hlc(t: i64) -> HLC { HLC { physical_time: t, logical_count: 0, node_id: 1 } }

    #[test]
    fn top_actions_returns_four_tuple() {
        let mut m = ActionOutcomeMatrix::new();
        m.observe(1, 0, true, hlc(1));
        m.observe(1, 0, true, hlc(2));
        let results = m.top_actions(0, 10, 1);
        assert_eq!(results.len(), 1);
        // Destructure to confirm the shape is (u8, f32, f32, u32).
        let (act, rate, wilson_lb, count) = results[0];
        assert_eq!(act, 1);
        assert!((rate - 1.0_f32).abs() < 1e-6, "rate should be 1.0");
        assert!(wilson_lb < rate, "Wilson LB must be < rate for finite n");
        assert_eq!(count, 2);
    }

    #[test]
    fn top_actions_result_non_increasing_in_wilson_lb() {
        // Three actions with identical raw rate (1.0) but different
        // evidence depth — Wilson LB order must equal returned order.
        let mut m = ActionOutcomeMatrix::new();
        m.observe(10, 3, true, hlc(1));                                    // 1/1
        for i in 0..5  { m.observe(11, 3, true, hlc(10 + i as i64)); }    // 5/5
        for i in 0..20 { m.observe(12, 3, true, hlc(20 + i as i64)); }    // 20/20
        let results = m.top_actions(3, 10, 1);
        assert_eq!(results.len(), 3);
        for i in 0..(results.len() - 1) {
            let (_, _, wlb_i, _) = results[i];
            let (_, _, wlb_next, _) = results[i + 1];
            assert!(wlb_i >= wlb_next,
                "result {i} wilson_lb {wlb_i} must be >= result {} wilson_lb {wlb_next}", i + 1);
        }
        // The returned wilson_lb must equal the cell's computed value.
        for (act, rate, wilson_lb, count) in &results {
            let key = ActionOutcomeKey::new(*act, 3);
            let cell = m.cells[&key];
            assert!((wilson_lb - cell.wilson_lower_bound()).abs() < 1e-6,
                "returned wilson_lb must equal cell.wilson_lower_bound()");
            assert!((rate - cell.success_rate()).abs() < 1e-6,
                "returned rate must equal cell.success_rate()");
            assert_eq!(*count, cell.total_count);
        }
    }

    #[test]
    fn top_actions_regression_wilson_order_differs_from_raw_rate_order() {
        // Regression guard for the original defect: results sorted by Wilson
        // LB but only raw rate returned, so order/value were mismatched.
        //
        // Action A (20): 1/1 — raw rate 1.0, thin evidence.
        // Action B (21): 80/100 — raw rate 0.8, strong evidence.
        // Raw-rate order: A > B. Wilson-LB order: B > A.
        let mut m = ActionOutcomeMatrix::new();
        m.observe(20, 8, true, hlc(1));
        for i in 0..80  { m.observe(21, 8, true,  hlc(2 + i as i64)); }
        for i in 0..20  { m.observe(21, 8, false, hlc(82 + i as i64)); }
        let results = m.top_actions(8, 2, 1);
        assert_eq!(results.len(), 2);
        // B must rank first (higher Wilson LB).
        assert_eq!(results[0].0, 21, "B must rank first by Wilson LB");
        assert_eq!(results[1].0, 20, "A must rank second");
        // Returned Wilson LBs are strictly ordered.
        assert!(results[0].2 > results[1].2, "Wilson LBs must be strictly decreasing");
        // Raw rate order is opposite — confirms divergence scenario.
        assert!(results[0].1 < results[1].1,
            "raw rate of B (0.8) must be less than A (1.0), confirming order/value divergence");
    }

    #[test]
    fn top_actions_honors_k_and_min_observations() {
        let mut m = ActionOutcomeMatrix::new();
        m.observe(1, 7, true, hlc(1));
        m.observe(2, 7, true, hlc(2));
        m.observe(2, 7, true, hlc(3));
        m.observe(3, 7, true, hlc(4));
        // k = 1 caps the result.
        assert_eq!(m.top_actions(7, 1, 1).len(), 1);
        // min_observations = 2 filters single-observation cells.
        let filtered = m.top_actions(7, 10, 2);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].0, 2);
    }
}
