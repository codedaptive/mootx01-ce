// ThresholdGate.swift
//
// Mission GLK-07 — The training-daemon admission gate.
//
// Per DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21 the training daemon
// is gated on transition count. Below the threshold the daemon is
// dormant — no enrichment, no matrix updates, no calibration work —
// so a tiny estate pays zero training cost. At or above the threshold
// the daemon is admitted and the pipeline runs on the GLK-04 scheduler.
//
// The threshold is manifest-set: the consumer chooses a value at
// estate instantiation and feeds it to the gate. The decision record
// also pins a provisional default (500 transitions) for callers that
// want the recommended floor without authoring their own.
//
// Transition counting. "Transitions" are state-changing audit verbs
// in the unified audit log: `capture`, `mutate`, `withdraw`, `expunge`,
// `reanchor`. Pure-read verbs (`recall`, `propose`, `associate`,
// `learn`, `dreamCompact`, `migrate`) and federation/key-custody verbs
// (`grantIssued`, `grantRevoked`, `keyDecayed`, `physicalKeyDecayed`)
// are intentionally excluded — they do not advance the substrate's row
// state, so they should not move the daemon toward activation. This is
// the same partition the matrix tier uses in `MatrixTier.rebuild` to
// decide which entries feed F / O updates, kept consistent here so a
// calibrated threshold against the audit log matches the cells the
// matrices will see.
//
// Wall-clock age is **not** part of the gate. The decision record
// explicitly downgrades age and row count to secondary signals; this
// gate honors the transition-count-only primary per the mission's
// "Known Ambiguities" §1 resolution.

import Foundation

// MARK: - Decision

/// Outcome of one `TrainingThresholdGate.decide(...)` call. Carries
/// the gate's verdict and the count it was measured against so the
/// caller (the daemon, diagnostics) can surface a single value rather
/// than re-deriving it.
public enum TrainingThresholdDecision: Sendable, Equatable {
    /// Estate has not yet crossed the configured threshold. The
    /// training daemon must perform no enrichment work; it may surface
    /// a diagnostic emission noting the dormant state.
    case dormant(transitionCount: Int, threshold: Int)

    /// Estate is at or above the configured threshold. The training
    /// daemon admits the enrichment pipeline.
    case active(transitionCount: Int, threshold: Int)

    /// True when the gate admits the pipeline.
    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// Transition count the decision was measured against. Convenient
    /// for diagnostic emissions that want to report progress toward
    /// the threshold without unpacking the enum.
    public var transitionCount: Int {
        switch self {
        case .dormant(let n, _): return n
        case .active(let n, _): return n
        }
    }

    /// Threshold the decision was measured against.
    public var threshold: Int {
        switch self {
        case .dormant(_, let t): return t
        case .active(_, let t): return t
        }
    }
}

// MARK: - Gate

/// The manifest-set transition-count gate. A pure value type with no
/// internal state — the same gate value can be reused across estates
/// or across ticks, and `decide` is a function of the threshold plus
/// the count derived from the caller-supplied audit log.
public struct TrainingThresholdGate: Sendable, Equatable, Codable {

    /// Provisional default per DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21.
    /// Callers may override at estate instantiation; this value is the
    /// floor below which the decision record warns the bootstrap
    /// heuristics carry the cognitive load on their own.
    public static let provisionalDefault: Int = 500

    /// The configured transition-count threshold. Stored as `Int` to
    /// match `UnifiedAuditLog.count` (which is the natural Swift
    /// `Dictionary.count` shape feeding the gate's input).
    public let transitionThreshold: Int

    /// Construct a gate with the supplied threshold. Negative inputs
    /// are clamped to zero — a "zero threshold" gate always admits,
    /// which is the documented semantics for tests that want the gate
    /// out of the way.
    public init(transitionThreshold: Int = provisionalDefault) {
        self.transitionThreshold = max(0, transitionThreshold)
    }

    // MARK: Decision

    /// Decide based on a pre-counted transition total. Used by the
    /// daemon when it already has the count in hand (the tick path
    /// computes it once and reuses it for both the gate and the
    /// diagnostic report).
    public func decide(transitionCount: Int) -> TrainingThresholdDecision {
        if transitionCount >= transitionThreshold {
            return .active(transitionCount: transitionCount,
                           threshold: transitionThreshold)
        }
        return .dormant(transitionCount: transitionCount,
                        threshold: transitionThreshold)
    }

    /// Decide directly from a `UnifiedAuditLog`. Counts the
    /// state-changing verbs documented in this file's header
    /// (capture, mutate, withdraw, expunge, reanchor) and feeds the
    /// total through `decide(transitionCount:)`. Pure read of the
    /// log; no side effects.
    public func decide(log: UnifiedAuditLog) -> TrainingThresholdDecision {
        decide(transitionCount: Self.transitionCount(in: log))
    }

    // MARK: Helpers

    /// Count the transitions in an audit log. Exposed so the daemon
    /// can show the same number in its diagnostic emission that the
    /// gate evaluated against. The five state-changing verbs are
    /// inlined rather than table-driven so a future grep for
    /// "transition verb" lands directly here.
    public static func transitionCount(in log: UnifiedAuditLog) -> Int {
        var count = 0
        for entry in log.orderedEntries {
            switch entry.verb {
            case .capture, .mutate, .withdraw, .expunge, .reanchor:
                count += 1
            case .recall, .propose, .associate, .learn,
                 .dreamCompact, .migrate,
                 // Federation grant-lifecycle / key-custody verbs record
                 // grant and key events, not drawer state-transitions,
                 // so they do not count toward the training threshold.
                 .grantIssued, .grantRevoked, .keyDecayed, .physicalKeyDecayed:
                continue
            }
        }
        return count
    }
}
