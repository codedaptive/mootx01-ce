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
    pub fn top_actions(&self, outcome: u8, k: usize, min_observations: u32)
                       -> Vec<(u8, f32, u32)> {
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
            .map(|(act, rate, _wilson, count)| (act, rate, count))
            .collect()
    }

    pub fn populated_cell_count(&self) -> usize {
        self.cells.len()
    }
}
