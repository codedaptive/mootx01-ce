// TemporalCompression.swift
//
// Hierarchical temporal compression per cookbook § 8.14.
//
// Builds on MomentSummary (§ 8.7): given a set of row fingerprints
// captured within a time window, produce a single OR-reduction
// fingerprint that summarizes the window. Temporal compression
// rolls those moment summaries up hierarchically:
//
//   hour → day → week → month → quarter → year
//
// Each level's window fingerprint is the OR-reduction of the
// lower-level windows that compose it. Roll-up is associative
// and commutative (inherited from OR-reduction), so the final
// summary is independent of roll-up order.
//
// Storage discipline: the substrate keeps the most recent
// (hour windows, day windows) hot in the bit-sliced tensor and
// progressively older windows in the SQLite tail. The dreaming
// daemon (§ 15 rule 6) advances windows hourly, daily, weekly,
// monthly, quarterly, and yearly on schedule.
//
// Used by:
//   § 8.14   Temporal compression definition (this file)
//   § 8.7    Moment summary (the underlying operation)
//   § 11.16  recall_similar_moments_by_summary primitive
//   § 15     Dreaming daemon rule 6 (window roll-up)

import Foundation
import SubstrateTypes

public enum WindowLevel: Int, Comparable, Sendable {
    case hour    = 0
    case day     = 1
    case week    = 2
    case month   = 3
    case quarter = 4
    case year    = 5

    public static func < (lhs: WindowLevel, rhs: WindowLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// Next coarser level, or nil if already at year (the coarsest).
    public var nextCoarser: WindowLevel? {
        return WindowLevel(rawValue: rawValue + 1)
    }

    /// Approximate seconds in one window of this level.
    public var approxSeconds: Int64 {
        switch self {
        case .hour:    return 3600
        case .day:     return 86_400
        case .week:    return 604_800
        case .month:   return 2_592_000
        case .quarter: return 7_776_000
        case .year:    return 31_536_000
        }
    }
}

public struct TemporalWindow: Equatable, Sendable {
    public let startHLC: HLC
    public let endHLC: HLC
    public let level: WindowLevel
    public var fingerprint: Fingerprint256
    public var rowCount: UInt32

    public init(startHLC: HLC,
                endHLC: HLC,
                level: WindowLevel,
                fingerprint: Fingerprint256,
                rowCount: UInt32) {
        self.startHLC = startHLC
        self.endHLC = endHLC
        self.level = level
        self.fingerprint = fingerprint
        self.rowCount = rowCount
    }

    /// Empty window for a level. Identity element for OR-reduction.
    public static func empty(level: WindowLevel) -> TemporalWindow {
        return TemporalWindow(startHLC: .zero,
                              endHLC: .zero,
                              level: level,
                              fingerprint: .zero,
                              rowCount: 0)
    }
}

public enum TemporalCompression {

    /// Compress a list of row fingerprints captured between startHLC
    /// and endHLC into a single window at the given level.
    public static func compress(rows: [Fingerprint256],
                                startHLC: HLC,
                                endHLC: HLC,
                                level: WindowLevel) -> TemporalWindow {
        var summary = Fingerprint256.zero
        for fp in rows { summary = summary.union(fp) }
        return TemporalWindow(startHLC: startHLC,
                              endHLC: endHLC,
                              level: level,
                              fingerprint: summary,
                              rowCount: UInt32(rows.count))
    }

    /// Roll a set of lower-level windows up to a single target-level
    /// window. The target level should be coarser than the input
    /// windows' level. OR-reduction is associative and commutative,
    /// so input ordering does not affect the result.
    public static func rollup(windows: [TemporalWindow],
                              to targetLevel: WindowLevel) -> TemporalWindow {
        guard !windows.isEmpty else {
            return .empty(level: targetLevel)
        }
        var summary = Fingerprint256.zero
        var totalRows: UInt32 = 0
        var minStart = windows[0].startHLC
        var maxEnd = windows[0].endHLC
        for w in windows {
            summary = summary.union(w.fingerprint)
            totalRows = totalRows &+ w.rowCount
            if w.startHLC < minStart { minStart = w.startHLC }
            if w.endHLC > maxEnd { maxEnd = w.endHLC }
        }
        return TemporalWindow(startHLC: minStart,
                              endHLC: maxEnd,
                              level: targetLevel,
                              fingerprint: summary,
                              rowCount: totalRows)
    }

    /// Roll all hour windows for a calendar day into a day window,
    /// all day windows for a calendar week into a week window, and
    /// so on, up to the requested level.
    public static func cascadeRollup(hourWindows: [TemporalWindow],
                                     upTo finalLevel: WindowLevel)
                                    -> [WindowLevel: [TemporalWindow]] {
        var byLevel: [WindowLevel: [TemporalWindow]] = [:]
        byLevel[.hour] = hourWindows

        var current: WindowLevel = .hour
        while current < finalLevel, let next = current.nextCoarser {
            let lowerWindows = byLevel[current] ?? []
            let bucketed = bucketByCoarserLevel(lowerWindows, coarser: next)
            byLevel[next] = bucketed.values
                .map { rollup(windows: $0, to: next) }
                .sorted { $0.startHLC < $1.startHLC }
            current = next
        }
        return byLevel
    }

    /// Bucket lower-level windows by the coarser-level slot they
    /// fall into. Uses physical-time anchors from each HLC.
    private static func bucketByCoarserLevel(_ windows: [TemporalWindow],
                                             coarser: WindowLevel)
                                            -> [Int64: [TemporalWindow]] {
        var buckets: [Int64: [TemporalWindow]] = [:]
        for w in windows {
            let anchor = w.startHLC.physicalSecondsSinceEpoch()
                       / coarser.approxSeconds
            buckets[anchor, default: []].append(w)
        }
        return buckets
    }
}
