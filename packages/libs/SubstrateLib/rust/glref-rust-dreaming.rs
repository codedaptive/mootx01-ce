// dreaming.rs
//
// Dreaming daemon per cookbook § 15. Mirror of
// glref-swift-DreamingDaemon.swift.
//
// Thirteen scheduled rules (cookbook § 15.2). The schedule
// resolver lives outside this file so tests can deterministically
// inject which rules fire on a given tick.

use substrate_types::hlc::HLC;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DreamingRule {
    MatrixDecay,
    KeystoneRefresh,
    LouvainRefresh,
    NmfRerun,
    CalibrationRefresh,
    TemporalCompression,
    AnomalyScan,
    AuditLogCompaction,
    FederationSync,
    PrivacyLedgerReset,
    BradleyTerryUpdate,
    ActionOutcomeUpdate,
    CognitionBundleExport,
}

impl DreamingRule {
    pub fn all() -> [DreamingRule; 13] {
        [
            DreamingRule::MatrixDecay,
            DreamingRule::KeystoneRefresh,
            DreamingRule::LouvainRefresh,
            DreamingRule::NmfRerun,
            DreamingRule::CalibrationRefresh,
            DreamingRule::TemporalCompression,
            DreamingRule::AnomalyScan,
            DreamingRule::AuditLogCompaction,
            DreamingRule::FederationSync,
            DreamingRule::PrivacyLedgerReset,
            DreamingRule::BradleyTerryUpdate,
            DreamingRule::ActionOutcomeUpdate,
            DreamingRule::CognitionBundleExport,
        ]
    }

    pub fn name(&self) -> &'static str {
        match self {
            DreamingRule::MatrixDecay              => "matrix_decay",
            DreamingRule::KeystoneRefresh          => "keystone_refresh",
            DreamingRule::LouvainRefresh           => "louvain_refresh",
            DreamingRule::NmfRerun                 => "nmf_rerun",
            DreamingRule::CalibrationRefresh       => "calibration_refresh",
            DreamingRule::TemporalCompression      => "temporal_compression",
            DreamingRule::AnomalyScan              => "anomaly_scan",
            DreamingRule::AuditLogCompaction       => "audit_log_compaction",
            DreamingRule::FederationSync           => "federation_sync",
            DreamingRule::PrivacyLedgerReset       => "privacy_ledger_reset",
            DreamingRule::BradleyTerryUpdate       => "bradley_terry_update",
            DreamingRule::ActionOutcomeUpdate      => "action_outcome_update",
            DreamingRule::CognitionBundleExport    => "cognition_bundle_export",
        }
    }
}

#[derive(Debug, Clone)]
pub enum RuleTrigger {
    FixedInterval(u64),    // seconds
    DailyAt { hour: u8, minute: u8 },
    OnEvent(String),
    ThresholdReached { metric: String, threshold: f64 },
}

#[derive(Debug, Clone)]
pub struct RuleSchedule {
    pub rule: DreamingRule,
    pub trigger: RuleTrigger,
    pub enabled_by_default: bool,
}

#[derive(Debug, Clone)]
pub struct DreamingDaemonConfig {
    pub schedules: Vec<RuleSchedule>,
}

impl Default for DreamingDaemonConfig {
    fn default() -> Self {
        Self {
            schedules: vec![
                RuleSchedule { rule: DreamingRule::MatrixDecay,
                               trigger: RuleTrigger::DailyAt { hour: 3, minute: 0 },
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::KeystoneRefresh,
                               trigger: RuleTrigger::FixedInterval(7 * 86_400),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::LouvainRefresh,
                               trigger: RuleTrigger::FixedInterval(30 * 86_400),
                               enabled_by_default: false },
                RuleSchedule { rule: DreamingRule::NmfRerun,
                               trigger: RuleTrigger::FixedInterval(30 * 86_400),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::CalibrationRefresh,
                               trigger: RuleTrigger::FixedInterval(7 * 86_400),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::TemporalCompression,
                               trigger: RuleTrigger::FixedInterval(3600),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::AnomalyScan,
                               trigger: RuleTrigger::FixedInterval(3600),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::AuditLogCompaction,
                               trigger: RuleTrigger::ThresholdReached {
                                   metric: "audit_event_count_since_last".to_string(),
                                   threshold: 100_000.0,
                               },
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::FederationSync,
                               trigger: RuleTrigger::FixedInterval(3600),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::PrivacyLedgerReset,
                               trigger: RuleTrigger::DailyAt { hour: 0, minute: 0 },
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::BradleyTerryUpdate,
                               trigger: RuleTrigger::OnEvent("RecallTrace.ingest".to_string()),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::ActionOutcomeUpdate,
                               trigger: RuleTrigger::OnEvent("Actuator.complete".to_string()),
                               enabled_by_default: true },
                RuleSchedule { rule: DreamingRule::CognitionBundleExport,
                               trigger: RuleTrigger::DailyAt { hour: 4, minute: 0 },
                               enabled_by_default: true },
            ],
        }
    }
}

pub trait DreamingRuleExecutor: Send + Sync {
    fn execute(&mut self, rule: DreamingRule, hlc: HLC) -> Result<(), String>;
}

pub struct DreamingDaemon<E: DreamingRuleExecutor> {
    pub config: DreamingDaemonConfig,
    pub executor: E,
}

impl<E: DreamingRuleExecutor> DreamingDaemon<E> {
    pub fn new(config: DreamingDaemonConfig, executor: E) -> Self {
        Self { config, executor }
    }

    /// Drive a single tick. Caller supplies which rules fire so
    /// tests can be deterministic.
    pub fn tick(&mut self, fire_rules: &[DreamingRule], hlc: HLC) -> Result<(), String> {
        for rule in fire_rules {
            self.executor.execute(*rule, hlc)?;
        }
        Ok(())
    }
}

/// Reference rule executor. Production substitutes a parallelizing
/// executor or a TestRuleExecutor that records invocations.
pub struct ReferenceRuleExecutor;

impl DreamingRuleExecutor for ReferenceRuleExecutor {
    fn execute(&mut self, rule: DreamingRule, _hlc: HLC) -> Result<(), String> {
        match rule {
            DreamingRule::MatrixDecay => Ok(()),
            DreamingRule::KeystoneRefresh => Ok(()),
            DreamingRule::LouvainRefresh => Ok(()),       // deferred v0.37
            DreamingRule::NmfRerun => Ok(()),
            DreamingRule::CalibrationRefresh => Ok(()),
            DreamingRule::TemporalCompression => Ok(()),
            DreamingRule::AnomalyScan => Ok(()),
            DreamingRule::AuditLogCompaction => Ok(()),
            DreamingRule::FederationSync => Ok(()),
            DreamingRule::PrivacyLedgerReset => Ok(()),
            DreamingRule::BradleyTerryUpdate => Ok(()),
            DreamingRule::ActionOutcomeUpdate => Ok(()),
            DreamingRule::CognitionBundleExport => Ok(()),
        }
    }
}
