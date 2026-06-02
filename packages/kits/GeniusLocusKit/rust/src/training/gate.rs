// training/gate.rs — Rust mirror of `ThresholdGate.swift`.
//
// The manifest-set transition-count gate. Below the threshold the
// training daemon is dormant; at or above it the daemon is admitted
// and the enrichment pipeline runs. Transition counting includes only
// the five state-changing verbs (capture, mutate, withdraw, expunge,
// reanchor); read-only verbs (recall, propose, associate, learn,
// dreamCompact, migrate) are excluded so a calibrated threshold matches
// the cells the matrices see.
//
// Wall-clock age is intentionally NOT part of the gate per
// DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21.

use crate::audit::{UnifiedAuditLog, UnifiedAuditVerb};

// MARK: - Decision

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrainingThresholdDecision {
    Dormant {
        transition_count: i64,
        threshold: i64,
    },
    Active {
        transition_count: i64,
        threshold: i64,
    },
}

impl TrainingThresholdDecision {
    pub fn is_active(&self) -> bool {
        matches!(self, TrainingThresholdDecision::Active { .. })
    }

    pub fn transition_count(&self) -> i64 {
        match self {
            TrainingThresholdDecision::Dormant {
                transition_count, ..
            } => *transition_count,
            TrainingThresholdDecision::Active {
                transition_count, ..
            } => *transition_count,
        }
    }

    pub fn threshold(&self) -> i64 {
        match self {
            TrainingThresholdDecision::Dormant { threshold, .. } => *threshold,
            TrainingThresholdDecision::Active { threshold, .. } => *threshold,
        }
    }
}

// MARK: - Gate

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrainingThresholdGate {
    pub transition_threshold: i64,
}

impl TrainingThresholdGate {
    /// Provisional default per DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21.
    pub const PROVISIONAL_DEFAULT: i64 = 500;

    pub fn new(transition_threshold: i64) -> Self {
        // Negative inputs clamp to zero — a zero-threshold gate always
        // admits. Matches the Swift initializer's clamp.
        Self {
            transition_threshold: transition_threshold.max(0),
        }
    }

    pub fn default_gate() -> Self {
        Self::new(Self::PROVISIONAL_DEFAULT)
    }

    /// Decide based on a pre-counted transition total.
    pub fn decide(&self, transition_count: i64) -> TrainingThresholdDecision {
        if transition_count >= self.transition_threshold {
            TrainingThresholdDecision::Active {
                transition_count,
                threshold: self.transition_threshold,
            }
        } else {
            TrainingThresholdDecision::Dormant {
                transition_count,
                threshold: self.transition_threshold,
            }
        }
    }

    /// Decide directly from a `UnifiedAuditLog`. Counts the same five
    /// state-changing verbs the Swift reference counts.
    pub fn decide_from_log(&self, log: &UnifiedAuditLog) -> TrainingThresholdDecision {
        self.decide(Self::transition_count(log))
    }

    /// Count transitions in an audit log. The five state-changing
    /// verbs are inlined so a grep for "transition verb" lands here.
    pub fn transition_count(log: &UnifiedAuditLog) -> i64 {
        let mut count: i64 = 0;
        for entry in log.ordered_entries() {
            match entry.verb {
                UnifiedAuditVerb::Capture
                | UnifiedAuditVerb::Mutate
                | UnifiedAuditVerb::Withdraw
                | UnifiedAuditVerb::Expunge
                | UnifiedAuditVerb::Reanchor => count += 1,
                UnifiedAuditVerb::Recall
                | UnifiedAuditVerb::Propose
                | UnifiedAuditVerb::Associate
                | UnifiedAuditVerb::Learn
                | UnifiedAuditVerb::DreamCompact
                | UnifiedAuditVerb::Migrate => continue,
            }
        }
        count
    }
}

impl Default for TrainingThresholdGate {
    fn default() -> Self {
        Self::default_gate()
    }
}
