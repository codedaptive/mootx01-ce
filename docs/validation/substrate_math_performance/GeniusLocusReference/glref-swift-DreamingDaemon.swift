// DreamingDaemon.swift
//
// Dreaming daemon per cookbook § 15 and paper § 11.5.
//
// The dreaming daemon is the substrate's offline maintenance
// process. It runs on a wall-clock schedule and performs the
// thirteen rules below. The name "dreaming" is from the
// hippocampal-replay literature: between waking activities the
// substrate replays and consolidates its representations.
//
// Thirteen rules (cookbook § 15.2):
//
//   1.  Matrix decay              nightly (90-day half-life for F, O;
//                                          365-day for C; 30-day for
//                                          calibration)
//   2.  Keystone score refresh    weekly  (eigenvalue centrality
//                                          on the co-activation graph)
//   3.  Louvain community refresh monthly (deferred until v0.37 lands
//                                          phase-2 of CommunityDetection)
//   4.  NMF rerun                 monthly (W and H factors over F)
//   5.  Calibration curve refresh weekly  (decay old observations,
//                                          recompute ECE and Brier)
//   6.  Temporal compression      tiered  (hour, day, week, month,
//                                          quarter, year roll-ups)
//   7.  Anomaly scan              hourly  (z-score and modified
//                                          z-score over recent ambient
//                                          streams)
//   8.  Audit log compaction      when    (after row count > 100K
//                                          new events; G-Set union
//                                          stays canonical)
//   9.  Federation sync           hourly  (push tier contributions,
//                                          pull peer contributions
//                                          where pairings active)
//   10. Privacy ledger reset      daily   (per-peer ε and δ usage
//                                          reset to 0 at local midnight)
//   11. Bradley-Terry weight      on RecallTrace ingest (pairwise
//       update                            comparisons across primitives)
//   12. Action-outcome update     on action close (one row per
//                                          completed actuation)
//   13. Cognition bundle export   nightly (PortableCognitionBundle to
//                                          designated path)
//
// Used by:
//   § 15 cookbook    Dreaming daemon definition (this file)
//   § 11.5 paper     Scheduled maintenance
//   § 6.5 cookbook   Action-outcome matrix (rule 12 writes here)
//   § 12.7 cookbook  Privacy ledger (rule 10 resets here)
//   § 13 cookbook    Cognition bundle (rule 13 exports here)

import Foundation

public enum DreamingRule: String, CaseIterable, Sendable {
    case matrixDecay              = "matrix_decay"
    case keystoneRefresh          = "keystone_refresh"
    case louvainRefresh           = "louvain_refresh"
    case nmfRerun                 = "nmf_rerun"
    case calibrationRefresh       = "calibration_refresh"
    case temporalCompression      = "temporal_compression"
    case anomalyScan              = "anomaly_scan"
    case auditLogCompaction       = "audit_log_compaction"
    case federationSync           = "federation_sync"
    case privacyLedgerReset       = "privacy_ledger_reset"
    case bradleyTerryUpdate       = "bradley_terry_update"
    case actionOutcomeUpdate      = "action_outcome_update"
    case cognitionBundleExport    = "cognition_bundle_export"
}

public enum RuleTrigger: Sendable {
    case fixedInterval(TimeInterval)   // run every N seconds
    case dailyAt(hour: Int, minute: Int)
    case onEvent(String)               // event name, e.g. "RecallTrace.ingest"
    case thresholdReached(metric: String, threshold: Double)
}

public struct RuleSchedule: Sendable {
    public let rule: DreamingRule
    public let trigger: RuleTrigger
    public let enabledByDefault: Bool

    public init(rule: DreamingRule, trigger: RuleTrigger,
                enabledByDefault: Bool = true) {
        self.rule = rule
        self.trigger = trigger
        self.enabledByDefault = enabledByDefault
    }
}

public struct DreamingDaemonConfig: Sendable {
    public let schedules: [RuleSchedule]

    public static let defaultConfig = DreamingDaemonConfig(schedules: [
        RuleSchedule(rule: .matrixDecay,           trigger: .dailyAt(hour: 3, minute: 0)),
        RuleSchedule(rule: .keystoneRefresh,       trigger: .fixedInterval(7 * 86_400)),
        RuleSchedule(rule: .louvainRefresh,        trigger: .fixedInterval(30 * 86_400),
                     enabledByDefault: false),
        RuleSchedule(rule: .nmfRerun,              trigger: .fixedInterval(30 * 86_400)),
        RuleSchedule(rule: .calibrationRefresh,    trigger: .fixedInterval(7 * 86_400)),
        RuleSchedule(rule: .temporalCompression,   trigger: .fixedInterval(3600)),
        RuleSchedule(rule: .anomalyScan,           trigger: .fixedInterval(3600)),
        RuleSchedule(rule: .auditLogCompaction,
                     trigger: .thresholdReached(metric: "audit_event_count_since_last", threshold: 100_000)),
        RuleSchedule(rule: .federationSync,        trigger: .fixedInterval(3600)),
        RuleSchedule(rule: .privacyLedgerReset,    trigger: .dailyAt(hour: 0, minute: 0)),
        RuleSchedule(rule: .bradleyTerryUpdate,    trigger: .onEvent("RecallTrace.ingest")),
        RuleSchedule(rule: .actionOutcomeUpdate,   trigger: .onEvent("Actuator.complete")),
        RuleSchedule(rule: .cognitionBundleExport, trigger: .dailyAt(hour: 4, minute: 0)),
    ])

    public init(schedules: [RuleSchedule]) {
        self.schedules = schedules
    }
}

/// Context handed to each rule's execute method. The substrate
/// wires this with the actual state objects on the device.
public struct DreamingContext {
    public var matrixF: MatrixF
    public var matrixO: MatrixO
    public var matrixC: MatrixC
    public var calibration: LLMCalibrationCurve
    public var actionOutcome: ActionOutcomeMatrix
    public var privacyLedger: PrivacyLedger
    public var auditStore: AuditEventStore
    public var workingSet: WorkingSet

    public init(matrixF: MatrixF, matrixO: MatrixO, matrixC: MatrixC,
                calibration: LLMCalibrationCurve,
                actionOutcome: ActionOutcomeMatrix,
                privacyLedger: PrivacyLedger,
                auditStore: AuditEventStore,
                workingSet: WorkingSet) {
        self.matrixF = matrixF
        self.matrixO = matrixO
        self.matrixC = matrixC
        self.calibration = calibration
        self.actionOutcome = actionOutcome
        self.privacyLedger = privacyLedger
        self.auditStore = auditStore
        self.workingSet = workingSet
    }
}

public protocol DreamingRuleExecutor {
    func execute(rule: DreamingRule,
                 context: inout DreamingContext,
                 hlc: HLC) throws
}

public final class DreamingDaemon {
    public let config: DreamingDaemonConfig
    private let executor: DreamingRuleExecutor

    public init(config: DreamingDaemonConfig = .defaultConfig,
                executor: DreamingRuleExecutor) {
        self.config = config
        self.executor = executor
    }

    /// Drive a single tick of the daemon. The caller supplies the
    /// list of rules whose triggers fire on this tick (the schedule
    /// resolver lives outside this file so testing can deterministic-
    /// ally inject which rules fire).
    public func tick(fireRules: [DreamingRule],
                     context: inout DreamingContext,
                     hlc: HLC) throws {
        for rule in fireRules {
            try executor.execute(rule: rule, context: &context, hlc: hlc)
        }
    }
}

// MARK: - Reference rule executor

/// Reference implementation that exercises each rule with the
/// substrate-canonical operation. Production may swap this for
/// a parallelizing executor or a TestRuleExecutor that records
/// invocations without side effects.
public struct ReferenceRuleExecutor: DreamingRuleExecutor {

    public init() {}

    public func execute(rule: DreamingRule,
                        context: inout DreamingContext,
                        hlc: HLC) throws {
        switch rule {
        case .matrixDecay:
            MatrixDecay.applyExponentialDecay(to: &context.matrixF,
                                              halfLifeDays: 90, atHLC: hlc)
            MatrixDecay.applyExponentialDecay(to: &context.matrixO,
                                              halfLifeDays: 90, atHLC: hlc)
            MatrixDecay.applyExponentialDecay(to: &context.matrixC,
                                              halfLifeDays: 365, atHLC: hlc)
            context.calibration.decay(factor: 0.9772)
            // (≈ 30-day half-life on weekly schedule)

        case .keystoneRefresh:
            // STUB — pre-v1.1: centrality dispatch not yet implemented in this
            // reference. See glref-swift-EigenvalueCentrality for the
            // algorithm; hlc is discarded until the dispatch is wired.
            _ = hlc

        case .louvainRefresh:
            // DEFERRED to v0.37 phase-2 of CommunityDetection.
            return

        case .nmfRerun:
            // STUB — pre-v1.1: Run NMFAlternatingLeastSquares against F matrix,
            // persist W and H to the cognition bundle.
            _ = hlc

        case .calibrationRefresh:
            // Already decayed above on the decay tick; recompute ECE and Brier
            // (results discarded here — STUB: bundle persistence not yet implemented).
            _ = context.calibration.expectedCalibrationError()
            _ = context.calibration.brierScore()

        case .temporalCompression:
            // STUB — pre-v1.1: Roll hour-windows up into day, week, month windows
            // via TemporalCompression.cascadeRollup.
            _ = hlc

        case .anomalyScan:
            // STUB — pre-v1.1: Scan recent ambient streams against rolling baselines.
            // Hit rows get the anomalous bit set in the bitmap tier.
            _ = hlc

        case .auditLogCompaction:
            // STUB — pre-v1.1: Compact the SQLite tail: drop obsolete tombstone-
            // chain entries, vacuum, checkpoint WAL.
            _ = hlc

        case .federationSync:
            // STUB — pre-v1.1: Build tier contributions, exchange with paired peers,
            // apply DP at the aggregator, consume privacy budget.
            _ = hlc

        case .privacyLedgerReset:
            context.privacyLedger.dailyReset()

        case .bradleyTerryUpdate:
            // STUB — pre-v1.1: Pairwise update on RecallTrace ingestion. The trace
            // surface lives outside this file.
            _ = hlc

        case .actionOutcomeUpdate:
            // STUB — pre-v1.1: ActionOutcomeMatrix.observe was already called by
            // ActuatorKit on completion; this rule's job is to propagate the
            // update through any dependent learned weights (e.g., outcome-aware
            // Proposal ranking).
            _ = hlc

        case .cognitionBundleExport:
            // STUB — pre-v1.1: Build a PortableCognitionBundle and write to the
            // estate's designated export path.
            _ = hlc
        }
    }
}
