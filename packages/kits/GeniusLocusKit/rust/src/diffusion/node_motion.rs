// node_motion.rs
//
// The node-layer motion model (ADR-DIFFUSION-001 §2/§4, build step §11.2).
// Rust port of NodeMotion.swift's pure fold. Diffusion is the time-axis peer of
// distillation; this is the BOTTOM layer (the node), folding one node's audit
// history {verb, hlc, anchor} into volatility + topic trajectory + reanchor.
//
// The decay weight exp(-λ·Δt_days) is the per-layer noise schedule: the node
// layer is HIGH frequency, so λ is LARGE. λ is an open ablation parameter
// (ADR §12). `fold` is pure and deterministic; the live convenience over the
// estate audit log is Swift-side glue (storage orchestration), not ported.
//
// Conformance: the structural outputs (trajectory, event_count, reanchored,
// last_event_physical_ms) are exact across ports; volatility is an exp()/f64
// computation, reproducible-within-config (arch spec §6), asserted to tolerance.

use crate::audit::log::{EntryUUID, UnifiedAuditEntry, UnifiedAuditValue};
use std::collections::HashSet;

const MS_PER_DAY: f64 = 86_400_000.0;

/// Informed-prior node decay constant, per day (fast layer). Ablate (ADR §12).
pub const DEFAULT_NODE_LAMBDA: f64 = 0.5;

/// The node-layer motion model for a single row. Mirrors Swift `NodeMotion`.
#[derive(Debug, Clone, PartialEq)]
pub struct NodeMotion {
    pub row_id: EntryUUID,
    pub volatility: f64,
    pub event_count: usize,
    pub last_event_physical_ms: Option<i64>,
    pub anchor_trajectory: Vec<u64>,
}

impl NodeMotion {
    /// The node's current (latest) UDC anchor, or None when none was recorded.
    pub fn current_anchor(&self) -> Option<u64> {
        self.anchor_trajectory.last().copied()
    }

    /// True when the node reanchored — its topic crossed >= 2 distinct codes.
    pub fn reanchored(&self) -> bool {
        let mut seen: HashSet<u64> = HashSet::new();
        for a in &self.anchor_trajectory {
            seen.insert(*a);
        }
        seen.len() > 1
    }
}

/// Fold a node's HLC-ordered audit entries into its motion model.
/// Deterministic over (entries, now_ms, lambda_per_day). Mirrors
/// `NodeMotionFold.fold` in Swift (which converts its `now: Date` to `now_ms`).
pub fn fold(
    entries: &[UnifiedAuditEntry],
    row_id: EntryUUID,
    now_ms: i64,
    lambda_per_day: f64,
) -> NodeMotion {
    let mut seen_physical: HashSet<i64> = HashSet::new();
    let mut volatility = 0.0_f64;
    let mut event_count = 0usize;
    let mut last_ms: Option<i64> = None;
    let mut trajectory: Vec<u64> = Vec::new();

    for entry in entries.iter().filter(|e| e.row_id == row_id) {
        let physical = entry.hlc.physical_time;

        // Distinct mutation moment -> one decay-weighted contribution. One drawer
        // write emits several field entries sharing one HLC.
        if seen_physical.insert(physical) {
            let age_days = (now_ms - physical).max(0) as f64 / MS_PER_DAY;
            volatility += (-lambda_per_day * age_days).exp();
            event_count += 1;
            if last_ms.map_or(true, |l| physical > l) {
                last_ms = Some(physical);
            }
        }

        // Topic trajectory: the anchor codes, in HLC order.
        if entry.field_path == "latticeAnchor" {
            if let UnifiedAuditValue::Integer(coded) = &entry.after_value {
                trajectory.push(*coded as u64);
            }
        }
    }

    NodeMotion {
        row_id,
        volatility,
        event_count,
        last_event_physical_ms: last_ms,
        anchor_trajectory: trajectory,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::log::{AuditTier, UnifiedAuditVerb};
    use substrate_types::hlc::HLC;
    use substrate_types::lattice_anchor::LatticeAnchor;

    const ROW: EntryUUID = EntryUUID([7u8; 16]);
    const DAY: i64 = 86_400_000;

    fn anchor_code(s: &str) -> u64 {
        LatticeAnchor::udc(s).udc_code
    }

    fn entry(ms: i64, field: &str, after: UnifiedAuditValue) -> UnifiedAuditEntry {
        UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC { physical_time: ms, logical_count: 0, node_id: 1 },
            UnifiedAuditVerb::Mutate,
            ROW,
            field.to_string(),
            UnifiedAuditValue::Null,
            after,
            None,
        )
    }

    #[test]
    fn folds_history() {
        let entries = vec![
            entry(8 * DAY, "operational", UnifiedAuditValue::Bitmap(1)),
            entry(8 * DAY, "latticeAnchor", UnifiedAuditValue::Integer(anchor_code("530") as i64)),
            entry(9 * DAY, "latticeAnchor", UnifiedAuditValue::Integer(anchor_code("004") as i64)),
            entry(10 * DAY, "adjective", UnifiedAuditValue::Bitmap(2)),
        ];
        let m = fold(&entries, ROW, 10 * DAY, 0.5);
        assert_eq!(m.event_count, 3);
        assert_eq!(m.anchor_trajectory, vec![anchor_code("530"), anchor_code("004")]);
        assert_eq!(m.current_anchor(), Some(anchor_code("004")));
        assert!(m.reanchored());
        assert_eq!(m.last_event_physical_ms, Some(10 * DAY));
        let expected = 1.0 + (-0.5f64).exp() + (-1.0f64).exp();
        assert!((m.volatility - expected).abs() < 1e-9);
    }

    #[test]
    fn empty_history() {
        let m = fold(&[], ROW, 0, 0.5);
        assert_eq!(m.event_count, 0);
        assert_eq!(m.volatility, 0.0);
        assert!(m.anchor_trajectory.is_empty());
        assert_eq!(m.current_anchor(), None);
        assert!(!m.reanchored());
    }

    #[test]
    fn stable_topic_not_reanchored() {
        let entries = vec![
            entry(3 * DAY, "latticeAnchor", UnifiedAuditValue::Integer(anchor_code("612") as i64)),
            entry(4 * DAY, "operational", UnifiedAuditValue::Bitmap(8)),
        ];
        let m = fold(&entries, ROW, 5 * DAY, 0.5);
        assert_eq!(m.event_count, 2);
        assert!(!m.reanchored());
        assert_eq!(m.current_anchor(), Some(anchor_code("612")));
    }
}
