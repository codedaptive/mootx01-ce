// ActionOutcomeMatrix.swift
//
// Action-outcome matrix per cookbook § 6.5.
//
// Tracks the observed success rate of each (action_kind, outcome_category)
// pair as the substrate's reinforcement signal for the Proposal flow and
// ActuatorKit. Cells accumulate counts; lookup returns success rate over
// total observations together with the last-update HLC.
//
//   action_outcome[a, o] = (success_count[a,o],
//                           total_count[a,o],
//                           last_update_hlc[a,o])
//
// Bitmap fields referenced (cookbook § 2.4):
//   o07 action_kind        — 6 bits, action enumerated against actuator
//                            allowlist (§ 14.2).
//   o08 outcome_category   — 6 bits, outcome enumerated
//                            {resolved, partial, persisted, regressed,
//                             timed_out, not_attempted, plus growth}.
//
// Decay: action_outcome HAS decay (cookbook § 6.8 table). Half-life:
// 90 days. Decay applied lazily by the dreaming daemon via MatrixDecay
// (glref-*-MatrixDecay).
//
// Storage estimate: 64 actions × 64 outcomes × 16 bytes = 64 KiB at
// full saturation; typical estates populate < 5% of cells.
//
// Used by:
//   § 6.5   Action-outcome matrix definition (this file)
//   § 11.9  Outcome-aware Proposal scoring
//   § 14    ActuatorKit outcome reporting
//   § 15    Dreaming daemon rule 12 (close-the-loop update)

import Foundation
import SubstrateTypes

public struct ActionOutcomeKey: Hashable, Comparable, Sendable {
    public let actionKind: UInt8
    public let outcomeCategory: UInt8

    public init(actionKind: UInt8, outcomeCategory: UInt8) {
        precondition(actionKind < 64,
                     "action_kind must fit in 6 bits (bitmap field o07)")
        precondition(outcomeCategory < 64,
                     "outcome_category must fit in 6 bits (bitmap field o08)")
        self.actionKind = actionKind
        self.outcomeCategory = outcomeCategory
    }

    @inlinable
    public var packed: UInt16 {
        return (UInt16(actionKind) << 8) | UInt16(outcomeCategory)
    }

    public static func < (lhs: ActionOutcomeKey, rhs: ActionOutcomeKey) -> Bool {
        return lhs.packed < rhs.packed
    }
}

public struct ActionOutcomeCell: Equatable, Sendable {
    public var successCount: UInt32
    public var totalCount: UInt32
    public var lastUpdateHLC: HLC

    public init(successCount: UInt32 = 0,
                totalCount: UInt32 = 0,
                lastUpdateHLC: HLC) {
        self.successCount = successCount
        self.totalCount = totalCount
        self.lastUpdateHLC = lastUpdateHLC
    }

    /// Empirical success rate. Zero for empty cells.
    @inlinable
    public var successRate: Float32 {
        guard totalCount > 0 else { return 0 }
        return Float32(successCount) / Float32(totalCount)
    }

    /// Wilson lower bound (95% confidence). Provides a more
    /// conservative ranking signal than raw rate for cells with
    /// few observations.
    public var wilsonLowerBound: Float32 {
        guard totalCount > 0 else { return 0 }
        let n = Float32(totalCount)
        let phat = successRate
        let z: Float32 = 1.96
        let denom = 1 + (z * z) / n
        let centre = phat + (z * z) / (2 * n)
        let margin = z * (phat * (1 - phat) / n + (z * z) / (4 * n * n)).squareRoot()
        return (centre - margin) / denom
    }
}

public struct ActionOutcomeMatrix: Sendable {
    public private(set) var cells: [ActionOutcomeKey: ActionOutcomeCell] = [:]

    public init() {}

    /// Record one (action, outcome) observation at HLC.
    public mutating func observe(action: UInt8,
                                 outcome: UInt8,
                                 success: Bool,
                                 at hlc: HLC) {
        let key = ActionOutcomeKey(actionKind: action, outcomeCategory: outcome)
        var cell = cells[key] ?? ActionOutcomeCell(lastUpdateHLC: hlc)
        cell.totalCount &+= 1
        if success { cell.successCount &+= 1 }
        cell.lastUpdateHLC = hlc
        cells[key] = cell
    }

    public func successRate(action: UInt8, outcome: UInt8) -> Float32? {
        let key = ActionOutcomeKey(actionKind: action, outcomeCategory: outcome)
        guard let cell = cells[key], cell.totalCount > 0 else { return nil }
        return cell.successRate
    }

    public func observationCount(action: UInt8, outcome: UInt8) -> UInt32 {
        let key = ActionOutcomeKey(actionKind: action, outcomeCategory: outcome)
        return cells[key]?.totalCount ?? 0
    }

    /// Best actions for the given outcome, ranked by Wilson lower
    /// bound (so under-observed cells do not float to the top).
    /// Ties broken by total count desc, then action ascending.
    ///
    /// Returns all four signals so callers see the same value the
    /// ranking was computed from:
    ///   action          — action_kind (6-bit field o07)
    ///   rate            — empirical success rate (successCount/totalCount)
    ///   wilsonLowerBound — 95 % Wilson interval lower bound used to rank;
    ///                      always ≤ rate; narrows toward rate as count grows
    ///   count           — total observations (minObservations floor applied)
    ///
    /// Returning rate without wilsonLowerBound would create an
    /// order/value mismatch: results are ordered by Wilson LB but the
    /// returned "rate" field would imply raw-rate ordering to callers.
    public func topActions(forOutcome outcome: UInt8,
                           k: Int,
                           minObservations: UInt32 = 1)
                          -> [(action: UInt8, rate: Float32, wilsonLowerBound: Float32, count: UInt32)] {
        let filtered = cells.compactMap {
            (key, cell) -> (UInt8, Float32, Float32, UInt32)? in
            guard key.outcomeCategory == outcome,
                  cell.totalCount >= minObservations else { return nil }
            return (key.actionKind, cell.successRate, cell.wilsonLowerBound, cell.totalCount)
        }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            if lhs.3 != rhs.3 { return lhs.3 > rhs.3 }
            return lhs.0 < rhs.0
        }
        return sorted.prefix(k).map { ($0.0, $0.1, $0.2, $0.3) }
    }

    /// Total number of populated cells.
    public var populatedCellCount: Int { return cells.count }
}
