// node_anomaly.rs
//
// The node-layer write-time anomaly read.
// Rust port of NodeAnomaly.swift's pure classifier. Diffusion integrates cold
// (dreaming) but is read HOT: at/after a write, classify a node's motion into a
// surfaceable anomaly — churning (rapid re-edits) or reanchored (topic moved).
//
// `classify` is pure and deterministic. The live read surface (folding the fresh
// per-row audit trail) is Swift-side glue (storage orchestration), not ported.

use genius_locus_kit::audit::log::EntryUUID;
use crate::diffusion::node_motion::NodeMotion;

/// Volatility at/above which a node is "churning". Subject to ablation.
pub const DEFAULT_CHURN_THRESHOLD: f64 = 3.0;

/// A node-layer anomaly verdict. Mirrors Swift `NodeAnomaly`.
#[derive(Debug, Clone, PartialEq)]
pub struct NodeAnomaly {
    pub row_id: EntryUUID,
    pub volatility: f64,
    pub is_churning: bool,
    pub reanchored: bool,
    pub current_anchor: Option<u64>,
}

impl NodeAnomaly {
    /// Any anomaly worth surfacing at write time.
    pub fn is_anomalous(&self) -> bool {
        self.is_churning || self.reanchored
    }
}

/// Classify a node's motion into a write-time anomaly verdict. Mirrors Swift
/// `NodeAnomalyClassifier.classify`.
pub fn classify(motion: &NodeMotion, churn_threshold: f64) -> NodeAnomaly {
    NodeAnomaly {
        row_id: motion.row_id,
        volatility: motion.volatility,
        is_churning: motion.volatility >= churn_threshold,
        reanchored: motion.reanchored(),
        current_anchor: motion.current_anchor(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn motion(volatility: f64, trajectory: Vec<u64>) -> NodeMotion {
        NodeMotion {
            row_id: EntryUUID([0u8; 16]),
            volatility,
            event_count: trajectory.len(),
            last_event_physical_ms: Some(1),
            anchor_trajectory: trajectory,
        }
    }

    #[test]
    fn churning_is_anomalous() {
        let a = classify(&motion(4.0, vec![100]), DEFAULT_CHURN_THRESHOLD);
        assert!(a.is_churning);
        assert!(!a.reanchored);
        assert!(a.is_anomalous());
    }

    #[test]
    fn reanchored_is_anomalous_when_calm() {
        let a = classify(&motion(0.5, vec![100, 200]), DEFAULT_CHURN_THRESHOLD);
        assert!(!a.is_churning);
        assert!(a.reanchored);
        assert!(a.is_anomalous());
        assert_eq!(a.current_anchor, Some(200));
    }

    #[test]
    fn stable_not_anomalous() {
        let a = classify(&motion(0.3, vec![100]), DEFAULT_CHURN_THRESHOLD);
        assert!(!a.is_anomalous());
    }

    #[test]
    fn threshold_honored() {
        let m = motion(2.5, vec![100]);
        assert!(classify(&m, 2.0).is_churning);
        assert!(!classify(&m, 3.0).is_churning);
    }
}
